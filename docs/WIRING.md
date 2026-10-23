# Wiring

## Lamp outputs (same as v1)

Relays are driven through ULN2003 (GPIO **HIGH = relay ON**).
If your relays work the opposite way, swap `RELAY_ON` / `RELAY_OFF` in the firmware.

| Lamp | GPIO | Lamp | GPIO | Lamp | GPIO |
|---|---|---|---|---|---|
| 1 | 4  | 6  | 5  | 11 | 26 |
| 2 | 13 | 7  | 21 | 12 | 27 |
| 3 | 16 | 8  | 22 | 13 | 32 |
| 4 | 17 | 9  | 23 | 14 | 33 |
| 5 | 18 | 10 | 25 | 15 | 12 |

> **GPIO12 note:** GPIO12 must be LOW when the ESP32 boots. ULN2003 keeps it LOW,
> so it is safe. Do **not** connect GPIO12 to a relay board that pulls the pin HIGH,
> or the ESP32 will not start.

## WiFi reset button (GPIO14)

```
  ESP32 GPIO14 ──────┐
                     │  push button (normally open)
  ESP32 GND    ──────┘
```

No resistor needed (internal pull-up is used).

**How to reset:** hold the button, power on the ESP32 (or press EN), keep holding
for 5 seconds. The blue LED blinks slowly while you hold and fast when the reset is done.
Router name/password and hotspot password are erased → open hotspot **"Smart Home"**.
Lamp names and states are kept.

## Status LED (GPIO2, on-board blue LED)

| LED | Meaning |
|---|---|
| ON (steady) | Connected to router |
| Short blink every 2 s | Hotspot mode |
| Fast blinking at start | Connecting to router |
