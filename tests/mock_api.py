#!/usr/bin/env python3
"""One mock server for all three provider APIs used by ddns-watch.sh (tests only).

  GET  /nic/update                      Strato dyndns2 (basic auth)
  POST /legacy                          netcup legacy CCP JSON API
  *    /v1/...                          netcup REST API (bearer key)
  POST /upnp/control                    router UPnP IGD GetExternalIPAddress (SOAP)
  POST /_reset   {"mode": "..."}        reset state; modes: normal, notfound, legacy, dupe, empty,
                                        upnp-cgnat, upnp-down, down (all provider APIs answer 503),
                                        dyn500 (dyndns2 answers HTTP 500 with "good")
  POST /notify                          records notifications (title, priority, auth, text)
  POST /gotify/message                  Gotify API (X-Gotify-Key GOTKEY, JSON), records messages
  POST /discord/api/webhooks/123/SECRETHOOK   Discord webhook (JSON content), records messages
  POST /slack/services/T0/B0/SECRETHOOK       Slack incoming webhook (JSON text), records messages
  GET  /heartbeat                       counts heartbeat pings
  GET  /release/latest                  {"tag_name": "v<release>"} (release set via /_reset)
  GET  /release/<path>                  file from $MOCK_RELEASE_DIR
  GET  /_state                          current records + request log (JSON)

Usage: mock_api.py PORT
"""
import base64, json, os, sys, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

STRATO_USER, STRATO_PASS = "example.com", 'p"a\\ss'
LEGACY = ("12345", "LEGKEY", "LEG'PASS")
TOKEN = "RESTTOKEN"
TOKEN_SPECIAL = 'R"E\\S T$&!%'   # a key with quote, backslash, space and shell characters
ZONE, DOMAIN_ID = "example.com", 4711
S = {}


def reset(mode="normal", release="9.9.9"):
    S.clear()
    S.update(mode=mode, log=[], strato=None, revs={"rev-active": "active"}, notify=[], gotify=[], discord=[], slack=[], heartbeat=0, release=release)
    S["rest"] = [
        {"identifier": "r1", "name": "@", "type": "NS", "rdata": "ns1.example.net.", "ttl": 86400, "immutable": True},
        {"identifier": "r2", "name": "@", "type": "A", "rdata": "192.0.2.1", "ttl": 300, "immutable": False},
        {"identifier": "r3", "name": "www", "type": "CNAME", "rdata": "example.com.", "ttl": 300, "immutable": False},
    ]
    S["legacy"] = [
        {"id": "1", "hostname": "@", "type": "A", "priority": "0", "destination": "192.0.2.1", "deleterecord": False, "state": "yes"},
        {"id": "2", "hostname": "www", "type": "CNAME", "priority": "0", "destination": "@", "deleterecord": False, "state": "yes"},
    ]
    if mode == "dupe":
        S["rest"].append({"identifier": "r4", "name": "@", "type": "A", "rdata": "192.0.2.2", "ttl": 300, "immutable": False})
        S["legacy"].append({"id": "3", "hostname": "@", "type": "A", "priority": "0", "destination": "192.0.2.2", "deleterecord": False, "state": "yes"})
    if mode == "empty":
        S["rest"], S["legacy"] = [], []


def env(result=None, errors=None):
    return {"success": not errors, "errors": errors or [], "messages": [], "meta": None, "result": result}


def err(code, msg):
    return env(errors=[{"code": code, "message": msg}])


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj, ctype="application/json"):
        b = b"" if obj is None else obj if isinstance(obj, bytes) else (obj.encode() if isinstance(obj, str) else json.dumps(obj).encode())
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        return json.loads(raw) if raw else None

    # ---- UPnP IGD (router): GetExternalIPAddress via SOAP
    def upnp(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        S["log"].append("POST /upnp")
        if S["mode"] == "upnp-down" or "GetExternalIPAddress" not in self.headers.get("SOAPAction", "") \
                or "GetExternalIPAddress" not in raw:
            return self.reply(500, "<error/>", "text/xml")
        ip = "100.64.12.34" if S["mode"] == "upnp-cgnat" else "81.2.69.142"
        xml = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
               '<u:GetExternalIPAddressResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">'
               f'<NewExternalIPAddress>{ip}</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>')
        return self.reply(200, xml, "text/xml")

    # ---- notification webhook (ntfy-like) and heartbeat
    def notify(self):
        n = int(self.headers.get("Content-Length") or 0)
        text = self.rfile.read(n).decode() if n else ""
        S["notify"].append({"title": self.headers.get("Title", ""), "priority": self.headers.get("Priority", ""),
                            "auth": self.headers.get("Authorization", ""), "text": text})
        return self.reply(200, {"ok": True})

    def route(self, method):
        u = urlparse(self.path)
        if u.path == "/upnp/control":
            return self.upnp()
        if u.path == "/notify":
            return self.notify()
        if u.path in ("/discord/api/webhooks/123/SECRETHOOK", "/slack/services/T0/B0/SECRETHOOK"):
            n = int(self.headers.get("Content-Length") or 0)
            msg = json.loads(self.rfile.read(n) or b"{}")
            field = "content" if u.path.startswith("/discord") else "text"
            if self.headers.get("Content-Type") != "application/json" or not msg.get(field):
                return self.reply(400, {"message": "Cannot send an empty message"})
            S["discord" if field == "content" else "slack"].append(msg)
            return self.reply(204 if field == "content" else 200, None if field == "content" else "ok", "text/plain")
        if u.path == "/gotify/message":
            n = int(self.headers.get("Content-Length") or 0)
            msg = json.loads(self.rfile.read(n) or b"{}")
            if self.headers.get("X-Gotify-Key") != "GOTKEY" or self.headers.get("Content-Type") != "application/json":
                return self.reply(401, {"error": "Unauthorized"})
            S["gotify"].append(msg)
            return self.reply(200, {"id": len(S["gotify"])})
        if u.path == "/heartbeat":
            S["heartbeat"] += 1
            return self.reply(200, "OK", "text/plain")
        if u.path == "/release/latest":
            return self.reply(200, {"tag_name": "v" + S["release"]})
        if u.path.startswith("/release/"):
            rel = os.path.normpath(u.path[len("/release/"):])
            f = os.path.join(os.environ.get("MOCK_RELEASE_DIR", "/nonexistent"), rel)
            if rel.startswith("..") or not os.path.isfile(f):
                return self.reply(404, "not found", "text/plain")
            with open(f, "rb") as fh:
                return self.reply(200, fh.read(), "application/octet-stream")
        if S.get("mode") == "down" and u.path not in ("/_reset", "/_state"):
            S["log"].append(f"{method} {u.path} (down)")
            return self.reply(503, "service unavailable", "text/plain")
        body = self.body()
        if u.path == "/_reset":
            reset((body or {}).get("mode", "normal"), (body or {}).get("release", "9.9.9"))
            return self.reply(200, {"ok": True})
        if u.path == "/_state":
            return self.reply(200, S)
        S["log"].append(f"{method} {u.path}" + (f" {json.dumps(body)}" if body else ""))
        if u.path == "/nic/update":
            return self.strato(u)
        if u.path == "/legacy":
            return self.legacy(body)
        if u.path.startswith("/v1/"):
            return self.rest(method, u, body)
        return self.reply(404, err("notFound", "route"))

    # ---- Strato dyndns2
    def strato(self, u):
        if S["mode"] == "dyn500":
            return self.reply(500, "good 81.2.69.1", "text/plain")
        auth = self.headers.get("Authorization", "")
        want = "Basic " + base64.b64encode(f"{STRATO_USER}:{STRATO_PASS}".encode()).decode()
        if auth != want:
            return self.reply(401, "badauth", "text/plain")
        q = parse_qs(u.query)
        if q.get("hostname") != [ZONE]:
            return self.reply(200, "nohost", "text/plain")
        ip = q.get("myip", [""])[0]
        res = ("nochg " if S["strato"] == ip else "good ") + ip.replace(",", " ")
        S["strato"] = ip
        return self.reply(200, res, "text/plain")

    # ---- netcup legacy
    def legacy(self, req):
        a, p = req["action"], req["param"]

        def ok(data):
            return self.reply(200, {"action": a, "status": "success", "statuscode": 2000, "shortmessage": "ok", "longmessage": "", "responsedata": data})

        def fail(code, msg):
            return self.reply(200, {"action": a, "status": "error", "statuscode": code, "shortmessage": msg, "longmessage": msg, "responsedata": ""})

        if a == "login":
            if (p.get("customernumber"), p.get("apikey"), p.get("apipassword")) != LEGACY:
                return fail(4013, "Validation Error")
            return ok({"apisessionid": "SID123"})
        if p.get("apisessionid") != "SID123":
            return fail(4001, "session invalid")
        if a == "logout":
            return ok("")
        if p.get("domainname") != ZONE or S["mode"] == "notfound":
            return fail(4013, "Domain not found")
        if a == "infoDnsRecords":
            return ok({"dnsrecords": S["legacy"]}) if S["legacy"] else fail(5029, "no records")
        if a == "updateDnsRecords":
            for r in p["dnsrecordset"]["dnsrecords"]:
                if r.get("deleterecord"):
                    S["legacy"] = [x for x in S["legacy"] if x["id"] != r["id"]]
                elif r.get("id"):
                    for x in S["legacy"]:
                        if x["id"] == r["id"]:
                            x["destination"] = r["destination"]
                else:
                    S["legacy"].append(dict(r, id=str(uuid.uuid4())[:8], state="yes"))
            return ok({"dnsrecords": S["legacy"]})
        return fail(4000, "unknown action")

    # ---- netcup REST
    def rest(self, method, u, body):
        if self.headers.get("Authorization") not in ("Bearer " + TOKEN, "Bearer " + TOKEN_SPECIAL):
            return self.reply(400, err("authenticationError", "invalid api key"))
        p = u.path.rstrip("/").split("/")[2:]  # after /v1
        if method == "GET" and p == ["domain"]:
            if S["mode"] == "notfound" or parse_qs(u.query).get("fqdn") != [ZONE]:
                return self.reply(404, err("resourceDoesNotExist", "domain not found"))
            return self.reply(200, env([{"id": DOMAIN_ID, "fqdn": ZONE, "isDnsManaged": S["mode"] != "legacy"}]))
        if p[:2] != ["domain", str(DOMAIN_ID)]:
            return self.reply(404, err("resourceDoesNotExist", "no such domain"))
        p = p[2:]
        if method == "GET" and p == ["dns", "revision"]:
            return self.reply(200, env([{"identifier": k, "state": v} for k, v in S["revs"].items()]))
        if method == "GET" and len(p) == 4 and p[:2] == ["dns", "revision"] and p[3] == "record":
            if p[2] not in S["revs"]:
                return self.reply(400, err("validationError", "bad revision"))
            return self.reply(200, env(S["rest"]))
        if method == "POST" and p == ["changeset"]:
            if body.get("autoCommit") is not True or body.get("strict") is not True:
                return self.reply(422, err("validationError", "test expects autoCommit+strict"))
            for d in body.get("delete") or []:
                m = [r for r in S["rest"] if (r["name"], r["type"], r["rdata"], r["ttl"]) == (d["name"], d["type"], d["rdata"], d["ttl"])]
                if not m:
                    return self.reply(422, err("validationError", f"strict: no record matches {d}"))
                S["rest"].remove(m[0])
            for c in body.get("create") or []:
                S["rest"].append(dict(c, identifier=str(uuid.uuid4())[:8], immutable=False))
            return self.reply(200, env({"identifier": "cs1"}))
        return self.reply(404, err("notFound", "route"))

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")


reset()
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
