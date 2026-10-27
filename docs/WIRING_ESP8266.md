# Wiring – NodeMCU ESP8266 + 8-channel relay card (8 lamps)

Firmware: `firmware/SmartHome_ESP8266/SmartHome_ESP8266.ino`
Board in Arduino IDE: **NodeMCU 1.0 (ESP-12E Module)**. The same Android app works.

## Relay card

| Relay card | NodeMCU | Lamp in app |
|---|---|---|
| IN1 | D0 | Lamp 1 |
| IN2 | D1 | Lamp 2 |
| IN3 | D2 | Lamp 3 |
| IN4 | D3 | Lamp 4 |
| IN5 | D4 | Lamp 5 |
| IN6 | D5 | Lamp 6 |
| IN7 | D6 | Lamp 7 |
| IN8 | D7 | Lamp 8 |
| GND | GND | |
| VCC | 5V supply | |

The relay card works **LOW = ON** (optocoupler type). The firmware is set for this.

### Power

8 relays need about **0.6 A at 5V**. A USB port is not enough. Use a separate
**5V 1A (or more)** supply for the relay card VCC, and connect its GND to the NodeMCU GND.
The NodeMCU can be powered from the same 5V on its **VIN** pin.

### Pins that must not change

- **D8 is not used.** A relay card on D8 pulls it HIGH and the ESP8266 will not boot.
- D3 and D4 must be HIGH when the board starts. The relay card keeps them HIGH, so they are OK.
- Lamp 5 (D4) may click very briefly at start – the ESP8266 sends boot messages on that pin.
  The on-board blue LED also lights when Lamp 5 is ON. Both are normal.

## WiFi reset button

```
  NodeMCU RX pin ──────┐
                       │  push button (normally open)
  NodeMCU GND    ──────┘
```

Hold the button, power on, keep holding **5 seconds** → WiFi settings erased →
open hotspot **"Smart Home"**. Serial Monitor still shows messages, and USB upload
still works (don't press the button while uploading).

## Differences from the ESP32 version

| | ESP32 | ESP8266 |
|---|---|---|
| Lamps | 15 | 8 |
| Reset button | GPIO14 | RX |
| Status LED | blue LED | none (D4 is a lamp) |
| App, cloud, timers, backup | ✔ | ✔ same |
