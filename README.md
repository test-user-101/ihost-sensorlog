# iHost Sensor Log

A small Docker add-on for the **SONOFF iHost / eWeLink CUBE** that does three things:

1. **Records** every sensor reading the gateway sees into a local time-series database on the TF card.
2. **Backs it up** to an external database over the internet or your LAN — and buffers everything locally when that link is down.
3. **Alerts you** by Telegram, email or WhatsApp when something you care about happens.

It is read-only against the gateway, so it does **not** interfere with the eWeLink CUBE web app or the eWeLink mobile app. They keep working exactly as before.

---

## Why this exists

The iHost has no sensor-history API. Its own UI graphs come from internal storage, and it keeps only a small number of records per data type. Anything you want to analyse later, you have to capture yourself — starting now. This add-on is that capture layer.

## How it works

```
                 ┌──────────────────────────── iHost (ARMv7, 4GB) ─────────────────────────────┐
                 │                                                                              │
  Zigbee/LAN ───▶│  eWeLink CUBE  ──SSE events──▶  collector  ──▶  SQLite on TF card            │
   sensors       │    (untouched)  ──REST poll──▶      │              │     │                   │
                 │                                     │              │     └──▶ CSV / JSON     │
                 │                              rules engine          │           export        │
                 │                                     │         forwarder (outbox)             │
                 └─────────────────────────────────────┼──────────────┼───────────────────────-─┘
                                                       ▼              ▼
                                            Telegram / email /   InfluxDB, Postgres via HTTP,
                                            WhatsApp alerts      MQTT, or your own endpoint
```

Key design decisions, and why:

| Decision | Reason |
|---|---|
| **SQLite, not a database server** | The iHost is a 32-bit Cortex-A7. InfluxDB 2.x and most modern DB images have no `linux/arm/v7` build. SQLite is a library, not a service: no second container, no port, ~zero RAM. |
| **Outbox pattern** (a `sent` flag per row) | The offline buffer and the backup mechanism are the same thing. Internet down → rows stay `sent=0` and pile up. Internet back → the backlog drains by itself. Nothing is ever dropped. |
| **SSE *plus* a periodic REST poll** | The live stream can silently drop. The poll every 10 minutes reconciles state, catches devices that never push, and fills gaps after a reconnect. |
| **Change-only writes + deadbands** | TF cards die from write amplification. Storing only real changes cuts writes by one to two orders of magnitude. A heartbeat every 15 min keeps graphs alive. |
| **Rows pruned only once backed up** | Retention never deletes data that hasn't reached your external DB. |
| **Alerts queued in SQLite, delivered separately** | An internet outage is exactly when you need the alert. Queued alerts go out on restore, stamped with when the condition actually occurred. |

Typical footprint: **~60–100 MB RAM**, near-zero idle CPU, and roughly **150–400 MB of database per year** for a few dozen sensors.

---

## Install on the iHost

### Step 1 — build and publish the image

The iHost pulls images from a registry; it cannot build them. Pick one route.

**Route A — you have Docker somewhere**

```sh
./build.sh YOUR-DOCKERHUB-USERNAME
```

**Route B — you don't have Docker anywhere**

Push this repo to GitHub. The included workflow (`.github/workflows/build.yml`) builds the ARMv7 image for free and pushes it to `ghcr.io/YOUR-USER/ihost-sensorlog`. Then make the package public:
*GitHub → Packages → ihost-sensorlog → Package settings → Change visibility → Public.*

> **This must be an `linux/arm/v7` image.** The iHost is a Rockchip RV1126, quad-core Cortex-A7 — 32-bit. Both routes above handle that; a plain `docker build` on an x86 laptop will not.

### Step 2 — prepare the iHost

1. Insert a **TF card** (Class 10+, 64 GB recommended, ideally a *high-endurance* card) and format it from the CUBE UI. Add-ons will not install without one.
2. Give the iHost a **static DHCP lease**. The add-on talks to it by address, and a changed IP breaks the link.

### Step 3 — install the add-on

1. **Docker** menu → create a **volume** named `sensorlog-data`.
2. **Docker** menu → **+** → search for your image name → *Add to list* → **Install**.
3. Click **RUN** and set:
   - **Network:** `Host`
   - **Volume:** `sensorlog-data` mounted at `/data`
   - **Environment variables:** see below (start with just `CUBE_BASE_URL` and `TZ`)
4. Open `http://<ihost-ip>:8126` and click **Pair with gateway**, then confirm the popup that appears on the iHost console.

That's it. Press **Poll now** and your devices should appear.

---

## Configuration

Everything is an environment variable — see `.env.example` for the annotated full list. The ones that matter on day one:

| Variable | Default | Notes |
|---|---|---|
| `CUBE_BASE_URL` | `http://ihost.local` | Use the IP if mDNS is unreliable on your network. |
| `TZ` | UTC | Set it (e.g. `Asia/Bahrain`) or alert timestamps will confuse you. |
| `SITE_NAME` | `iHost` | Appears in alert subjects. Useful if you run more than one. |
| `RETENTION_DAYS` | `400` | Local history depth. |
| `POLL_INTERVAL_SEC` | `600` | Reconciliation sweep. Don't disable it. |
| `SINK_TYPE` | `none` | `none`, `influx2`, `influx1`, `http`, `mqtt`. |
| `WEB_TOKEN` | *(empty)* | Set a secret if you don't want anyone on your LAN opening the page. |

### External backup targets

**InfluxDB 2.x / InfluxDB Cloud**
```
SINK_TYPE=influx2
SINK_URL=https://eu-central-1-1.aws.cloud2.influxdata.com
SINK_TOKEN=...
SINK_ORG=your-org
SINK_BUCKET=ihost
```

**InfluxDB 1.x** — `SINK_TYPE=influx1`, `SINK_URL`, `SINK_DB`, optional `SINK_USER`/`SINK_PASS`.

**Your own endpoint** — `SINK_TYPE=http`, `SINK_URL=https://…`. Receives batched JSON:
```json
{"source":"Home","readings":[{"ts":1790000000,"device":"a4c138…","capability":"temperature","field":"temperature","value":22.5,"text":null}]}
```

**MQTT** — `SINK_TYPE=mqtt`, `MQTT_HOST`, etc. Publishes retained QoS-1 messages to `ihost/<serial>/<capability>/<field>`.

Press **Test external DB** in the UI after configuring.

---

## Alerts

### Telegram — recommended, free, instant

1. Message **@BotFather** on Telegram, send `/newbot`, copy the token → `TELEGRAM_BOT_TOKEN`.
2. Send your new bot any message, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy `chat.id` → `TELEGRAM_CHAT_ID`.

### Email

Standard SMTP. **Gmail and Outlook require an app password**, not your account password. Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`, `SMTP_TO`.

### WhatsApp — read this before you start

There is no simple WhatsApp API. Three drivers are supported; pick by `WHATSAPP_DRIVER`:

| Driver | What it takes | Honest assessment |
|---|---|---|
| `meta` | Meta Business account, a dedicated phone number not already on WhatsApp, and an **approved message template** | The legitimate route. Alerts are business-initiated and fall outside the 24-hour service window, so freeform text will be rejected — you **must** set `WA_TEMPLATE_NAME`. Approval takes days; utility templates are billed per message in most regions. |
| `twilio` | Twilio account, sandbox or approved sender | Fastest to get working. Same template rules, paid. |
| `webhook` | Any relay you control (CallMeBot, n8n, your own bridge) | Free and trivial, but unofficial relays are rate-limited and can vanish. |

Not supported, deliberately: `whatsapp-web.js` / Baileys style libraries. They violate WhatsApp's terms, risk your number being banned, and need headless Chromium — which will not run on 32-bit ARM anyway.

**Recommendation: Telegram as the primary channel, email as backup, WhatsApp only if you have a business account already.**

### Rules

Alert rules live in `/data/rules.json`, editable from the **Alert rules** box in the UI (it validates before saving and reloads immediately). A sensible starting set is created on first run.

| Type | Fires when | Key fields |
|---|---|---|
| `threshold` | a numeric value crosses a limit | `sn`, `capability`, `field`, `op`, `value`, `unit` |
| `offline` | a device goes offline | `sn` (or `"*"` for all) |
| `no_data` | a device stops reporting | `sn`, `for_sec` |
| `gateway_down` | the iHost API is unreachable | — |
| `forwarder_stalled` | backups have been failing | — |
| `db_size` | the local DB passes a size limit | `max_mb` |

Common fields: `for_sec` (condition must hold this long before firing — kills false alarms), `cooldown_sec` (minimum gap between repeats), `channels`, `message`, `enabled`.

```json
{
  "id": "freezer-warm",
  "type": "threshold",
  "sn": "a4c1380000000002",
  "capability": "temperature",
  "field": "temperature",
  "op": ">", "value": -10, "unit": "°C",
  "for_sec": 600,
  "channels": ["telegram", "email"],
  "message": "{device} is at {value}{unit} — above {limit}{unit} for {for_min} minutes."
}
```

Placeholders available in `message`: `{device}`, `{sn}`, `{value}`, `{limit}`, `{unit}`, `{capability}`, `{for_min}`, `{unsent}`, `{db_mb}`.

The `deadbands` block at the top of the file controls how much a value must move before it's stored at all — e.g. `{"temperature": 0.2}` ignores wobble under 0.2°.

---

## Getting your data out

- **Web UI** → *Export* → CSV or JSON. Accepts `-24h`, `-30d`, ISO dates, or blank for everything.
- **Direct URL:** `http://<ihost-ip>:8126/export.csv?from=-7d&sn=<serial>`
- **API:** `/api/status`, `/api/devices`, `/export.json`, `/healthz`
- **The file itself:** `sensorlog.db` on the TF card is a plain SQLite database. Any tool can read it.

---

## Running it somewhere else

The identical image runs on anything — NAS, mini PC, Raspberry Pi — and that is often the better place for it: more disk, no 32-bit constraints, no risk to the hub.

```sh
docker run -d --name ihost-sensorlog \
  -p 8126:8126 -v ihost-data:/data \
  -e CUBE_BASE_URL=http://192.168.1.50 \
  -e TZ=Asia/Bahrain \
  YOUR-USER/ihost-sensorlog:latest
```

Local development without any hardware:

```sh
pip install -r requirements.txt
python -m tests.test_e2e      # 43 checks against a mock gateway
python -m tests.mock_gateway  # then point CUBE_BASE_URL at :18080
```

---

## Troubleshooting

**Pairing fails** — the confirmation popup appears on the CUBE console in your browser; open `http://<ihost-ip>` in another tab before pressing Pair. You have about 90 seconds.

**Worked, then stopped after a reboot** — the iHost's IP changed. Set a static lease. Tokens themselves survive reboots; only a factory reset invalidates them.

**Add-on won't install from Docker Hub** — confirm the image has an `arm/v7` tag. Some firmware versions have also had intermittent trouble pulling from Docker Hub specifically; a custom HTTPS registry (GHCR) is the workaround.

**`/data is not writable`** — the volume must be mounted at `/data` and owned by UID 1000. The image runs as UID 1000 for this reason; recreate the volume if it was made by another container.

**Readings stopped but the device is fine** — check *Last event* in the UI. If the stream shows disconnected but polls succeed, you're still collecting at `POLL_INTERVAL_SEC` resolution; the stream reconnects on its own with backoff.

**Alerts not arriving** — the UI lists each channel's configuration state. Use the Test buttons: they report the actual error from the provider.

---

## License

MIT. Use it, fork it, break it.
