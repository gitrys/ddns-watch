# Notifications and heartbeat

ddns-watch runs quietly in the background. Two optional helpers tell you when something is wrong:

| | Notification (`NOTIFY_URL`) | Heartbeat (`HEARTBEAT_URL`) |
|---|---|---|
| What | ddns-watch **sends a message** when updates keep failing | ddns-watch **calls a URL** after every good run |
| Tells you | "the DNS update is failing" (wrong key, provider down ...) | "this machine went quiet" (powered off, no network, service stopped) |
| Why both | a dead machine cannot send a message | only the heartbeat notices that |
| Services | ntfy, Gotify | Healthchecks.io, Uptime Kuma |

Both are set in `sudo ddns-watch setup` (step 6), or in `/etc/ddns-watch/config`. Test them any time:

```bash
sudo ddns-watch test-notify
```

## When you get a message

- **Right away** when the provider rejects the update for good (key wrong or revoked, unknown
  hostname). ddns-watch then stops trying until you change the config or the key.
- **After `NOTIFY_AFTER` minutes** (default 15) of temporary errors (provider down, no internet).
- **Once more** when it works again.

No messages on normal days: no news is good news. For "it is still alive" use the heartbeat.

---

## Notification with ntfy (easiest)

[ntfy](https://ntfy.sh) delivers messages to the ntfy app on your phone. No account needed.

1. Install the **ntfy** app (Android: Play Store / F-Droid, iOS: App Store).
2. Make up a **long, random topic name**, e.g. `ddns-home-7f3k9q2xw4`. On the public server
   anyone who knows the name can read and send messages, so treat it like a password.
3. In the app: **+** → *Subscribe to topic* → enter the name (server `ntfy.sh`).
4. In `sudo ddns-watch setup`, step 6, as notification URL:
   ```
   https://ntfy.sh/ddns-home-7f3k9q2xw4
   ```
   Access token: Enter (none).
5. Answer **y** to "Send a test now?". The message should appear on your phone within seconds.

### Your own ntfy server

If you run ntfy yourself (e.g. as a Docker container), use your server's URL, e.g.
`https://ntfy.example.com/ddns`. If the topic is protected, create an access token in ntfy
(`ntfy token add <user>` or in the web app) and enter it as access token in the setup. It is
stored encrypted (`notify-token`) and sent as `Authorization: Bearer ...`.

## Notification with Gotify

[Gotify](https://gotify.net) is a self-hosted push server with an Android app.

1. In the Gotify web UI: **Apps** → **Create application** (e.g. "ddns-watch") → copy its **token**.
2. In the setup, step 6:
   - notification URL: `https://gotify.example.com/message` (your server + `/message`)
   - access token: the application token
3. Test with "Send a test now?".

ddns-watch recognizes Gotify by the `/message` ending and sends JSON with title, message and
priority (8 for "rejected", 5 otherwise). If your URL looks different, set `NOTIFY_TYPE=gotify`
in `/etc/ddns-watch/config` (`ntfy` forces the other format).

## Other webhooks

With `NOTIFY_TYPE=ntfy` (the default for any other URL) ddns-watch sends a plain-text POST with the
message as body and the headers `Title`, `Priority` and `Tags`. Many services accept that, for
example Home Assistant webhooks or simple self-written receivers.

---

## Heartbeat with Healthchecks.io

[Healthchecks.io](https://healthchecks.io) is free for up to 20 checks (or self-hosted).

1. Create an account, then **Add Check**.
2. Set **Period: 5 minutes** and **Grace: 10 minutes**. ddns-watch pings at most once a minute,
   at least every 5 minutes (the IPv4 check), so this leaves room for a short hiccup.
3. Copy the **ping URL** (`https://hc-ping.com/<uuid>`) into the setup as heartbeat URL.
4. Under **Integrations** choose how Healthchecks reaches you: e-mail, ntfy, Telegram, ...

If the pings stop for period + grace, you get an alarm, and a "back up" message later.

## Heartbeat with Uptime Kuma

1. **Add New Monitor** → type **Push**.
2. **Heartbeat Interval: 300** seconds, **Retries: 1**.
3. Copy the **push URL** into the setup as heartbeat URL. (Keep its `?status=up&msg=OK`
   parameters as they are.)
4. Add a notification to the monitor (Uptime Kuma supports ntfy, Gotify, e-mail ...).

---

## Settings in `/etc/ddns-watch/config`

```bash
NOTIFY_URL=https://ntfy.sh/ddns-home-7f3k9q2xw4
NOTIFY_TYPE=auto          # auto | ntfy | gotify
NOTIFY_AFTER=15           # minutes of temporary errors before a message
HEARTBEAT_URL=https://hc-ping.com/<uuid>
```

Token (optional): `sudo ddns-watch set-secret notify-token`. Changes apply on the next run.

## Troubleshooting

- `sudo ddns-watch test-notify` sends both and prints what failed.
- `journalctl -u ddns-watch -u ddns-watch-ipv4 | grep -i -e notif -e heartbeat` shows past attempts.
- ntfy: wrong topic name in the app vs. the URL is the most common cause.
- Gotify: the token must be an **application** token, not a client token.
