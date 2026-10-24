<p align="center">
  <img src="app/assets/icon/icon-512.png" width="120" alt="Smart Home icon">
</p>

<h1 align="center">Smart Home – ESP32 15 Lamp Controller</h1>

<p align="center">
  ESP32 firmware + colourful Android app (Flutter) to switch 15 lamps.<br>
  Works as its own WiFi hotspot <b>or</b> on your home router.
</p>

---

## Features

- **15 lamps ON / OFF**, plus **ALL ON / ALL OFF**
- **Hotspot mode** – open WiFi `Smart Home` → `http://192.168.4.1`
- **Router mode** – device joins your home WiFi; the app **finds it automatically**
  (UDP broadcast + network scan, no IP typing)
- **Cloud control (MQTT)** through `broker.mqtt-dashboard.com` – switch lamps from **any network**
  (mobile data, office…). The app uses local WiFi when it can and the cloud when it can't.
- **Device IP shown** in the app header, on the web page and in the Serial Monitor
- **Auto-OFF timer** – turn a lamp ON and pick "OFF after 5 / 15 / 30 min…" (runs on the ESP32,
  works even when the phone is away)
- **Remembers lamp states after a power cut** (lamps with a running timer come back OFF)
- **Rename lamps** (Kitchen, Bedroom…)
- **JSON API** + **JSON backup download / upload**
- **WiFi reset button on GPIO14** – hold 5 s at power on → back to open hotspot
- **Safe WiFi change** (also from the cloud) – if new router settings fail, the old router is used again
- **Backup hotspot** – if the router is down, the device starts the `Smart Home` hotspot
  and keeps retrying the router
- Old URLs still work: `/Lamp_1_ON` … `/Lamp_15_OFF`, `/All_ON`, `/All_OFF`
- Browser pages: `/` (lamps) and `/setup` (WiFi settings) – no app needed

## Repository layout

```
firmware/SmartHome_ESP32/   Arduino sketch (.ino)
app/                        Flutter Android app
docs/API.md                 HTTP / JSON API
docs/WIRING.md              Pins, GPIO14 button, status LED
.github/workflows/          Builds APK + firmware automatically
```

---

## 1. Flash the ESP32

1. Arduino IDE → **Boards Manager** → install **esp32 by Espressif** (3.x recommended).
2. **Library Manager** → install **ArduinoJson** by Benoit Blanchon (**7.x**) and
   **PubSubClient** by Nick O'Leary (2.8).
   Remove old ArduinoJson 6 copies from `Documents\Arduino\libraries` if you have them.
3. Open `firmware/SmartHome_ESP32/SmartHome_ESP32.ino`.
4. Board: **ESP32 Dev Module** → Upload.
5. Serial Monitor (115200) shows: `Hotspot 'Smart Home' (OPEN) started. IP: 192.168.4.1`

Wiring: see [docs/WIRING.md](docs/WIRING.md). Add a push button between **GPIO14 and GND**.

## 2. Get the Android app

### Easy way – GitHub Actions (no Flutter on your PC)

1. Push this repo to GitHub.
2. Open the **Actions** tab → latest **Build** run → download **SmartHome-apk**.
3. To make a Release with the APK and firmware: create a tag, e.g. `git tag v1.0.0 && git push --tags`.

### Build on your PC

```bash
cd app
flutter create --platforms=android --org com.example --project-name smart_home .
dart run tool/setup_android.dart
flutter pub get
flutter build apk --release
# APK: app/build/app/outputs/flutter-apk/app-release.apk
```

> `flutter create` only adds the missing `android/` folder – it does not touch `lib/`.
> `setup_android.dart` adds the internet permission, allows `http://` and copies the icon.
> Change `com.example` to your own package name (e.g. `com.yourname`).

---

## 3. First start

1. Phone WiFi → connect to **Smart Home** (no password).
   If the phone says *"No internet – stay connected?"* choose **Yes**.
2. Open the app → it finds `192.168.4.1` automatically.
3. **Settings → WiFi mode:**
   - **Hotspot**: set a hotspot password (recommended), or
   - **Router**: tap the scan icon, pick your WiFi, enter the password.
4. **Save & restart** → connect the phone to the same WiFi → **Search again**.

Forgot a password? Hold the **GPIO14** button while powering on for **5 seconds**.

## 4. Use it from anywhere (cloud)

1. Put the device in **Router mode** (its router needs internet).
2. Open the app **once on the same WiFi** – the app saves the device's secret cloud key.
3. Now on mobile data or any other WiFi just open the app → it connects through the cloud
   (header shows **☁ Cloud** and the device IP).
4. Another phone: **Settings → Cloud → copy key**, then on the other phone
   **Connect through cloud** → paste the key.

---

## සිංහලෙන් කෙටියෙන්

1. Arduino IDE එකේ **ArduinoJson (7.x)** සහ **PubSubClient** libraries install කරලා firmware එක upload කරන්න.
2. Phone එක **"Smart Home"** WiFi එකට connect කරන්න (password නැහැ).
3. App එක open කරාම device එක automatically හොයාගන්නවා.
4. **Settings** එකෙන් hotspot password එකක් දාන්න, නැත්නම් **Router** තෝරලා ගෙදර WiFi එකට connect කරන්න.
5. Lamp card එක tap කරාම ON/OFF වෙනවා. ⏱ button එකෙන් "මිනිත්තු X කින් OFF" timer එක දාන්න.
6. Cloud: device එක **Router mode** එකේ තියලා, app එක එක පාරක් ගෙදර WiFi එකේ open කරන්න. ඊට පස්සේ
   mobile data හරි වෙන ඕනම network එකක හරි ඉඳන් lamps on/off කරන්න පුළුවන් (☁ Cloud).
7. Device එකේ IP එක app එකේ උඩ header එකේ සහ web page එකේ පෙන්නනවා.
8. Password අමතක වුණොත්: **GPIO14 button** එක ඔබාගෙන power on කරලා **තත්පර 5ක්** තියාගන්න.

---

## API

See [docs/API.md](docs/API.md). Example:

```bash
curl "http://192.168.4.1/api/lamp?id=3&state=on"
curl "http://192.168.4.1/api/timer?id=3&minutes=30"
curl  http://192.168.4.1/api/export > backup.json
```

## Security note

The hotspot starts **open** so the first setup is easy. Set a hotspot password in the app
(a yellow warning is shown until you do). The API has no login – anyone on the same WiFi
can control the lamps, so keep your WiFi password private.

`broker.mqtt-dashboard.com` is a **public** broker. Your lamps are protected only by the
random secret key in the topic name. Don't post the key online; if it leaks, tap
**Settings → Cloud → New key**. For more security use a private broker (e.g. HiveMQ Cloud
free plan) – broker, port, username and password can be changed in the app.

## License

MIT – see [LICENSE](LICENSE). Replace `Duleepa Pushpa Kumara` / `Duleepaku` with your details.
