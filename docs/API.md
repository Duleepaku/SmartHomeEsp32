# ESP32 HTTP API

Base URL: `http://192.168.4.1` (hotspot) or the router IP the app finds.
All `/api/...` replies are JSON. Errors: `{"ok":false,"error":"..."}` with HTTP 400/404.

## Lamps

| Method | URL | What it does |
|---|---|---|
| GET | `/api/status` | All lamps |
| GET/POST | `/api/lamp?id=3&state=on` | `state` = `on`, `off`, `toggle` |
| GET/POST | `/api/lamp?id=3&timer=30` | Lamp ON, OFF after 30 min (`timer=0` cancels) |
| GET/POST | `/api/timer?id=3&minutes=30` | Same as above |
| GET/POST | `/api/all?state=off` | All lamps ON/OFF |
| POST | `/api/name` form `id=3&name=Kitchen` | Rename (max 24 chars, empty = default) |

`/api/status` reply:

```json
{
  "ok": true,
  "lamps": [
    {"id": 1, "name": "Kitchen", "on": true, "timer": 1795},
    {"id": 2, "name": "Lamp 2",  "on": false, "timer": 0}
  ],
  "mode": "hotspot",
  "uptime": 523
}
```

`timer` = seconds until the lamp turns OFF (0 = no timer). Max timer: 1440 min (24 h).

## Daily schedules (Router mode)

Each lamp can have one daily schedule: ON at `HH:MM`, OFF at `HH:MM`, every day.
The device gets the time from the internet (NTP, Sri Lanka time UTC+5:30), so schedules
work in **Router mode** only. They run on the device – the phone can be off.

| Method | URL | What it does |
|---|---|---|
| GET | `/api/schedule` | Same as `/api/status` |
| POST | `/api/schedule` form `id=1&enabled=1&on=18:00&off=06:00` | Save a schedule (`enabled=0` = off) |

MQTT command: `{"cmd":"sched_set","id":1,"enabled":true,"on":"18:00","off":"06:00"}`

Every lamp in `/api/status` has `sch` (true/false), `sch_on`, `sch_off` (minutes after
midnight, e.g. 1080 = 18:00). The status also has `time_ok` and `time` ("HH:MM").

Rules:
- ON time later than OFF time (18:00 → 06:00) runs over midnight.
- After a power cut, when the time is known again, each scheduled lamp is set to the
  right state (e.g. power back at 21:00 with 18:00–06:00 → lamp ON).
- Switching a lamp by hand is allowed; the schedule switches it again at the next ON/OFF time.
- Saving a schedule while inside its ON period switches the lamp ON straight away.
- Schedules are included in the JSON backup.

## Backup (JSON)

| Method | URL | What it does |
|---|---|---|
| GET | `/api/export` | Download backup |
| POST | `/api/import` body = backup JSON | Restore. Add `?names=0` or `?states=0` to skip a part |

Backup format:

```json
{
  "format": "smarthome-backup",
  "version": 1,
  "fw": "2.0.0",
  "lamps": [
    {"id": 1, "name": "Kitchen", "on": true},
    {"id": 2, "name": "Lamp 2",  "on": false}
  ]
}
```

## WiFi & device

| Method | URL | What it does |
|---|---|---|
| GET | `/api/info` | Device info (mode, IPs, firmware, MAC...) |
| GET | `/api/wifi` | Saved WiFi settings (no passwords) |
| POST | `/api/wifi` | Save + restart (see below) |
| GET | `/api/scan` | Nearby WiFi networks |
| GET | `/api/mqtt` | Cloud settings (key, broker, connected) |
| POST | `/api/mqtt` | `enabled`, `host`, `port`, `user`, `pass`, `new_key=1` |
| POST | `/api/reboot` | Restart |
| POST | `/api/reset_wifi` | Erase WiFi settings, restart as open hotspot |

`POST /api/wifi` form fields:

- `mode=hotspot` or `mode=router`
- `ssid`, `pass` – router (needed for `router`; `pass` missing + same SSID = keep old password)
- `ap_pass` – hotspot password: missing = keep, empty = open hotspot, else 8–63 chars

If the device is on a working router and you change the router settings, the old
router is kept as a backup: when the new one fails, the device goes back to the old one.

## Cloud (MQTT)

Default broker: `broker.mqtt-dashboard.com:1883` (public). Works in **Router mode** only.
Every device has a random secret key (see `/setup`, the app, or the Serial Monitor).
All topics start with `smarthome/<key>/`:

| Topic | Direction | Payload |
|---|---|---|
| `cmd` | → device | `{"req":"a1","cmd":"lamp","id":3,"state":"on"}` |
| `reply` | ← device | `{"req":"a1","cmd":"lamp","ok":true,"lamps":[...]}` |
| `status` | ← device (retained) | same as `/api/status` + `ip`, `rssi`, `fw` |
| `online` | ← device (retained) | `online` / `offline` |
| `lamp/3/set` | → device | `ON`, `OFF`, `TOGGLE` (for MQTT dashboard apps) |
| `lamp/3/state` | ← device (retained) | `ON` / `OFF` |

Commands (`cmd`): `status`, `info`, `lamp`, `all`, `timer`, `name`, `export`,
`import` (`"data":{backup}`, `"names":true`, `"states":true`), `wifi_get`, `wifi_set`,
`scan`, `mqtt_get`, `mqtt_set`, `reboot`, `reset_wifi`. Arguments are the same as the HTTP API.

Test from a PC:

```bash
mosquitto_sub -h broker.mqtt-dashboard.com -t 'smarthome/<key>/#' -v
mosquitto_pub -h broker.mqtt-dashboard.com -t 'smarthome/<key>/lamp/1/set' -m ON
```

> The broker is public. The secret key is the only protection – keep it private,
> and make a new key in the app if someone else got it.

## Discovery

The app sends the UDP text `SMARTHOME_DISCOVER` to port **4210** (broadcast).
The board replies with the same JSON as `/api/info`. If broadcast is blocked,
the app scans every IP of the phone's WiFi subnet for `/api/info`.

## Old URLs (v1 / MIT App Inventor) – still work

`/Lamp_1_ON` … `/Lamp_15_OFF`, `/All_ON`, `/All_OFF`, `/` (web page), `/setup` (WiFi page).
