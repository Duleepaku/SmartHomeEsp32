// ============================================================
//  Smart Home - 8 Lamp Controller   (NodeMCU ESP8266 + 8-channel relay card)
//  Firmware v3.0.0  (ESP8266 version - same app, same API as ESP32)
//
//  * 8 lamps (relay card IN1..IN8) on D0..D7, state remembered after a power cut
//  * Hotspot mode : open WiFi "Smart Home"  ->  http://192.168.4.1
//  * Router mode  : joins your home WiFi, the app finds it automatically
//  * CLOUD (MQTT) : control from ANY network through broker.mqtt-dashboard.com
//  * "Turn OFF after X minutes" timer, lamp names, JSON backup
//  * Old URLs still work:  /Lamp_1_ON ... /Lamp_8_OFF , /All_ON , /All_OFF
//
//  WiFi reset button : RX pin (GPIO3) <-> GND
//  -----------------------------------------
//  Hold the button while powering on, keep holding for 5 seconds.
//  WiFi settings are erased -> open "Smart Home" hotspot.
//  (RX is used for the button, so Serial Monitor is OUTPUT ONLY.
//   Uploading over USB still works - just don't press the button.)
//
//  D8 is not used: a relay card on D8 stops the board from booting.
//
//  Required libraries (Arduino IDE -> Library Manager):
//      ArduinoJson   by Benoit Blanchon   (version 7.x)
//      PubSubClient  by Nick O'Leary      (version 2.8)
//  Board: "NodeMCU 1.0 (ESP-12E Module)"   (esp8266 by ESP8266 Community 3.x)
// ============================================================

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <WiFiUdp.h>
#include <ESP8266mDNS.h>
#include <LittleFS.h>
#include <ArduinoJson.h>
#include <PubSubClient.h>

#define FW_VERSION "3.0.0"

// ---------------- Settings you may change ----------------
const char AP_SSID[]  = "Smart Home";    // hotspot name
const char HOSTNAME[] = "smarthome";     // http://smarthome.local (PC / iPhone)

#define DEFAULT_MQTT_HOST  "broker.mqtt-dashboard.com"
#define DEFAULT_MQTT_PORT  1883
#define MQTT_TOPIC_ROOT    "smarthome"

#define RESET_BUTTON_PIN   3     // RX pin, button to GND (internal pull-up)
#define RESET_HOLD_MS   5000     // hold time for WiFi reset
// No status LED: the on-board LED is on D4, which is used for Lamp 5.

#define DISCOVERY_PORT  4210     // UDP port used by the app to find the board

// ---- 8-channel relay card (optocoupler): LOW = relay ON ----
// true  = LOW = ON  (relay card)
// false = HIGH = ON (ULN2003 / transistor)
const bool lampActiveLow[] = {
  true, true, true, true,     // Lamp 1-4
  true, true, true, true      // Lamp 5-8
};

// ---- 8 lamps on NodeMCU -> relay card IN1..IN8 ----
// D8 is NOT used: a relay card on D8 stops the ESP8266 from booting.
const int NUM_LAMPS = 8;
const int lampPins[NUM_LAMPS] = {
  D0,  // Lamp 1  IN1  (GPIO16)
  D1,  // Lamp 2  IN2  (GPIO5)
  D2,  // Lamp 3  IN3  (GPIO4)
  D3,  // Lamp 4  IN4  (GPIO0)  relay card keeps it HIGH at boot = OK
  D4,  // Lamp 5  IN5  (GPIO2)  relay card keeps it HIGH at boot = OK, on-board LED
  D5,  // Lamp 6  IN6  (GPIO14)
  D6,  // Lamp 7  IN7  (GPIO12)
  D7   // Lamp 8  IN8  (GPIO13)
};

inline int pinLevel(int i, bool on) { return (on != lampActiveLow[i]) ? HIGH : LOW; }

// ---------------- Internal constants ----------------
#define STA_CONNECT_TIMEOUT_MS  20000UL    // router connect attempt
#define STA_LOST_TO_AP_MS       60000UL    // router lost this long -> backup hotspot
#define STA_RETRY_INTERVAL_MS  300000UL    // backup hotspot: retry router every 5 min
#define STATE_SAVE_DELAY_MS      1500UL    // wait before writing flash (less wear)
#define STATUS_PUBLISH_DELAY_MS   300UL    // MQTT: group quick changes
#define STATUS_REFRESH_MS       60000UL    // MQTT: re-publish status every minute
#define MQTT_BUFFER_SIZE         2048
#define MAX_TIMER_MINUTES        1440      // 24 hours
#define NAME_MAX_LEN               48     // bytes (Sinhala letters use 3 bytes each)
#define KEY_LEN                    12

// ---------------- Runtime state ----------------
bool          lampState[NUM_LAMPS];
bool          timerActive[NUM_LAMPS];
unsigned long lampTimerEnd[NUM_LAMPS];      // millis() when the lamp turns OFF
String        lampName[NUM_LAMPS];

// WiFi settings
String apPass;        // "" = open hotspot
String staSsid;
String staPass;
bool   wantRouter = false;
bool   verifyPending = false;   // new router settings not yet confirmed
String prevSsid, prevPass;      // restored if the new ones fail

enum NetMode { MODE_AP, MODE_STA, MODE_AP_FALLBACK };
NetMode netMode = MODE_AP;

unsigned long staLostSince   = 0;
unsigned long lastRetryAt    = 0;
bool          retrying       = false;
unsigned long retryStartedAt = 0;

bool          statesDirty   = false;
unsigned long statesDirtyAt = 0;
bool          restartPending = false;
unsigned long restartAt      = 0;

// MQTT settings / state
bool     mqttEnabled = true;
String   mqttHost = DEFAULT_MQTT_HOST;
uint16_t mqttPort = DEFAULT_MQTT_PORT;
String   mqttUser, mqttPass;
String   deviceKey;
String   mqttBase;                       // smarthome/<key>  (set at connect)
unsigned long mqttLastTry  = 0;
unsigned long mqttRetryMs  = 0;
bool     mqttReconnectPending = false;   // settings changed -> reconnect
bool     statusDirty     = true;
unsigned long statusDirtyAt   = 0;
unsigned long lastStatusPubAt = 0;
uint32_t publishedMask   = 0;
bool     publishAllStates = true;

// small queue for incoming MQTT messages (handled in loop, not in callback)
#define MQTT_QUEUE 4
String   qTopic[MQTT_QUEUE];
String   qPayload[MQTT_QUEUE];
int      qHead = 0, qCount = 0;

// ---- Small "Preferences" replacement: one JSON file per namespace in LittleFS ----
class Prefs {
 public:
  bool begin(const char *ns, bool readOnly) {
    path_ = String("/") + ns + ".json";
    ro_ = readOnly; dirty_ = false;
    doc_.clear();
    File f = LittleFS.open(path_, "r");
    if (f) { if (deserializeJson(doc_, f)) doc_.clear(); f.close(); }
    if (!doc_.is<JsonObject>()) doc_.to<JsonObject>();
    return true;
  }
  void end() {
    if (dirty_ && !ro_) {
      File f = LittleFS.open(path_, "w");
      if (f) { serializeJson(doc_, f); f.close(); }
    }
    dirty_ = false;
    doc_.clear();
  }
  void clear()                                   { doc_.to<JsonObject>(); dirty_ = true; }
  String   getString(const char *k, const String &d) { return doc_[k].is<const char *>() ? String(doc_[k].as<const char *>()) : d; }
  bool     getBool(const char *k, bool d)            { return doc_[k].is<bool>() ? doc_[k].as<bool>() : d; }
  uint32_t getUInt(const char *k, uint32_t d)        { return doc_[k].is<uint32_t>() ? doc_[k].as<uint32_t>() : d; }
  uint16_t getUShort(const char *k, uint16_t d)      { return doc_[k].is<uint16_t>() ? doc_[k].as<uint16_t>() : d; }
  void putString(const char *k, const String &v) { set(k, v); }
  void putBool(const char *k, bool v)            { set(k, v); }
  void putUInt(const char *k, uint32_t v)        { set(k, v); }
  void putUShort(const char *k, uint16_t v)      { set(k, v); }
 private:
  template <typename T> void set(const char *k, T v) {
    if (doc_[k].isNull() || doc_[k].as<T>() != v) { doc_[k] = v; dirty_ = true; }
  }
  JsonDocument doc_;
  String path_;
  bool ro_ = false, dirty_ = false;
};

ESP8266WebServer server(80);
WiFiUDP      udp;
Prefs        prefs;
WiFiClient   mqttNet;
PubSubClient mqtt(mqttNet);

void markStatesDirty();

// ============================================================
//  Small helpers
// ============================================================
String defaultName(int i) { return "Lamp " + String(i + 1); }

String currentIP()
{
  if (WiFi.status() == WL_CONNECTED) return WiFi.localIP().toString();
  return WiFi.softAPIP().toString();
}

const char *modeName()
{
  switch (netMode) {
    case MODE_STA:         return "router";
    case MODE_AP_FALLBACK: return "hotspot_backup";
    default:               return "hotspot";
  }
}

// read arguments that may arrive as JSON numbers/bools (MQTT) or strings (HTTP)
bool aHas(JsonVariantConst a, const char *k) { return !a[k].isNull(); }

String aStr(JsonVariantConst a, const char *k, const String &def = "")
{
  JsonVariantConst v = a[k];
  if (v.isNull()) return def;
  if (v.is<const char *>()) return String(v.as<const char *>());
  if (v.is<bool>()) return v.as<bool>() ? "1" : "0";
  if (v.is<long>()) return String(v.as<long>());
  return def;
}

long aInt(JsonVariantConst a, const char *k, long def = 0)
{
  JsonVariantConst v = a[k];
  if (v.isNull()) return def;
  if (v.is<bool>()) return v.as<bool>() ? 1 : 0;
  if (v.is<long>()) return v.as<long>();
  if (v.is<float>()) return (long)v.as<float>();
  if (v.is<const char *>()) return String(v.as<const char *>()).toInt();
  return def;
}

bool aBool(JsonVariantConst a, const char *k, bool def)
{
  JsonVariantConst v = a[k];
  if (v.isNull()) return def;
  if (v.is<bool>()) return v.as<bool>();
  String s = aStr(a, k);
  s.toLowerCase();
  if (s == "1" || s == "true" || s == "on" || s == "yes") return true;
  if (s == "0" || s == "false" || s == "off" || s == "no") return false;
  return def;
}

// ============================================================
//  Storage (flash)
// ============================================================
void loadWifiSettings()
{
  prefs.begin("wifi", true);
  apPass        = prefs.getString("ap_pass", "");
  staSsid       = prefs.getString("sta_ssid", "");
  staPass       = prefs.getString("sta_pass", "");
  wantRouter    = prefs.getBool("router", false);
  verifyPending = prefs.getBool("verify", false);
  prevSsid      = prefs.getString("prev_ssid", "");
  prevPass      = prefs.getString("prev_pass", "");
  prefs.end();
}

void saveWifiSettings()
{
  prefs.begin("wifi", false);
  prefs.putString("ap_pass", apPass);
  prefs.putString("sta_ssid", staSsid);
  prefs.putString("sta_pass", staPass);
  prefs.putBool("router", wantRouter);
  prefs.putBool("verify", verifyPending);
  prefs.putString("prev_ssid", prevSsid);
  prefs.putString("prev_pass", prevPass);
  prefs.end();
}

void clearWifiSettings()
{
  prefs.begin("wifi", false);
  prefs.clear();
  prefs.end();
  apPass = ""; staSsid = ""; staPass = ""; wantRouter = false;
  verifyPending = false; prevSsid = ""; prevPass = "";
}

String makeKey()
{
  const char chars[] = "abcdefghjkmnpqrstuvwxyz23456789";   // no 0/o/1/l/i
  String k;
  for (int i = 0; i < KEY_LEN; i++) k += chars[(ESP.random() % (sizeof(chars) - 1))];
  return k;
}

void saveMqttSettings()
{
  prefs.begin("mqtt", false);
  prefs.putBool("en", mqttEnabled);
  prefs.putString("host", mqttHost);
  prefs.putUShort("port", mqttPort);
  prefs.putString("user", mqttUser);
  prefs.putString("pass", mqttPass);
  prefs.putString("key", deviceKey);
  prefs.end();
}

void loadMqttSettings()
{
  prefs.begin("mqtt", true);
  mqttEnabled = prefs.getBool("en", true);
  mqttHost    = prefs.getString("host", DEFAULT_MQTT_HOST);
  mqttPort    = prefs.getUShort("port", DEFAULT_MQTT_PORT);
  mqttUser    = prefs.getString("user", "");
  mqttPass    = prefs.getString("pass", "");
  deviceKey   = prefs.getString("key", "");
  prefs.end();
  if (deviceKey.length() < 8) {           // first boot: make a secret key
    deviceKey = makeKey();
    saveMqttSettings();
  }
}

void saveName(int i)
{
  prefs.begin("lamps", false);
  char key[16];
  snprintf(key, sizeof(key), "n%d", i + 1);
  prefs.putString(key, lampName[i]);
  prefs.end();
  markStatesDirty();
}

// Lamps with a running timer are saved as OFF: after a power cut
// they stay OFF, all other lamps come back to their last state.
void saveStatesNow()
{
  uint32_t mask = 0;
  for (int i = 0; i < NUM_LAMPS; i++)
    if (lampState[i] && !timerActive[i]) mask |= (1UL << i);

  prefs.begin("lamps", false);
  if (prefs.getUInt("states", 0xFFFFFFFF) != mask) prefs.putUInt("states", mask);
  prefs.end();
  statesDirty = false;
}

// something changed: save to flash later + publish to cloud
void markStatesDirty()
{
  statesDirty   = true;
  statesDirtyAt = millis();
  statusDirty   = true;
  statusDirtyAt = millis();
}

// ============================================================
//  Lamps & timers
// ============================================================
void setLamp(int index, bool on)
{
  lampState[index] = on;
  digitalWrite(lampPins[index], pinLevel(index, on));
  if (!on) timerActive[index] = false;     // manual OFF cancels the timer
  markStatesDirty();
}

void cancelTimer(int index)
{
  timerActive[index] = false;
  markStatesDirty();
}

// Turns the lamp ON and switches it OFF after 'minutes'
void startTimer(int index, long minutes)
{
  if (minutes <= 0) { cancelTimer(index); return; }
  if (minutes > MAX_TIMER_MINUTES) minutes = MAX_TIMER_MINUTES;
  setLamp(index, true);
  timerActive[index]  = true;
  lampTimerEnd[index] = millis() + (unsigned long)minutes * 60000UL;
  markStatesDirty();
}

long timerRemainingSec(int index)
{
  if (!timerActive[index]) return 0;
  long rem = (long)(lampTimerEnd[index] - millis());
  return rem > 0 ? (rem + 999) / 1000 : 0;
}

void checkTimers()
{
  unsigned long now = millis();
  for (int i = 0; i < NUM_LAMPS; i++) {
    if (timerActive[i] && (long)(now - lampTimerEnd[i]) >= 0) {
      Serial.printf("Timer finished: Lamp %d OFF\n", i + 1);
      setLamp(i, false);
    }
  }
}

void initLamps()
{
  // Set the OFF level before enabling the outputs (no relay click at boot)
  for (int i = 0; i < NUM_LAMPS; i++) {
    digitalWrite(lampPins[i], pinLevel(i, false));
    pinMode(lampPins[i], OUTPUT);
    lampState[i]   = false;
    timerActive[i] = false;
  }

  prefs.begin("lamps", true);
  uint32_t mask = prefs.getUInt("states", 0);
  for (int i = 0; i < NUM_LAMPS; i++) {
    char key[16];
    snprintf(key, sizeof(key), "n%d", i + 1);
    lampName[i] = prefs.getString(key, defaultName(i));
  }
  prefs.end();

  // Restore the state from before the power cut
  for (int i = 0; i < NUM_LAMPS; i++) {
    bool on = (mask >> i) & 1UL;
    lampState[i] = on;
    digitalWrite(lampPins[i], pinLevel(i, on));
  }
  statesDirty = false;
}

String cleanName(String s, int index)
{
  s.trim();
  s.replace("\n", " ");
  s.replace("\r", " ");
  if (s.length() > NAME_MAX_LEN) {
    int cut = NAME_MAX_LEN;                                  // don't cut a UTF-8 letter in half
    while (cut > 0 && ((uint8_t)s[cut] & 0xC0) == 0x80) cut--;
    s = s.substring(0, cut);
  }
  if (s.length() == 0) s = defaultName(index);
  return s;
}

// ============================================================
//  GPIO14 reset button (checked once at boot)
// ============================================================
void checkResetButton()
{
  pinMode(RESET_BUTTON_PIN, INPUT_PULLUP);
  delay(50);
  if (digitalRead(RESET_BUTTON_PIN) != LOW) return;

  Serial.println("Reset button pressed - keep holding for 5 seconds...");
  unsigned long start = millis();
  while (digitalRead(RESET_BUTTON_PIN) == LOW) {
    if (millis() - start >= RESET_HOLD_MS) {
      clearWifiSettings();
      Serial.println("WiFi settings erased -> open 'Smart Home' hotspot");
      while (digitalRead(RESET_BUTTON_PIN) == LOW) delay(10);   // wait for release
      break;
    }
    delay(10);
  }
}

// ============================================================
//  WiFi
// ============================================================
void startMDNS()
{
  MDNS.end();
  if (MDNS.begin(HOSTNAME)) MDNS.addService("http", "tcp", 80);
}

void printBanner()
{
  Serial.println("------------------------------------------");
  Serial.printf(" Mode       : %s\n", modeName());
  if (WiFi.status() == WL_CONNECTED)
    Serial.printf(" Router IP  : %s   (%s)\n", WiFi.localIP().toString().c_str(), staSsid.c_str());
  if (netMode != MODE_STA)
    Serial.printf(" Hotspot IP : %s   (%s)\n", WiFi.softAPIP().toString().c_str(), AP_SSID);
  Serial.printf(" Cloud key  : %s\n", deviceKey.c_str());
  Serial.println("------------------------------------------");
}

void startHotspot(bool fallback)
{
  WiFi.mode(fallback ? WIFI_AP_STA : WIFI_AP);
  const char *pass = (apPass.length() >= 8) ? apPass.c_str() : NULL;   // NULL = open
  WiFi.softAP(AP_SSID, pass);
  netMode = fallback ? MODE_AP_FALLBACK : MODE_AP;
  if (fallback) WiFi.disconnect(false);       // stop STA auto-retry (keeps AP channel stable)
  lastRetryAt = millis();
  retrying    = false;

  Serial.printf("Hotspot '%s' (%s) started%s\n", AP_SSID, pass ? "password" : "OPEN",
                fallback ? "  [backup - router not reachable]" : "");
  startMDNS();
  printBanner();
}

bool connectRouter()
{
  Serial.printf("Connecting to router '%s'", staSsid.c_str());
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(staSsid.c_str(), staPass.c_str());

  unsigned long start = millis();
  unsigned long dot = 0;
  while (WiFi.status() != WL_CONNECTED && millis() - start < STA_CONNECT_TIMEOUT_MS) {
    delay(100);
    if (millis() - dot > 1000) { Serial.print('.'); dot = millis(); }
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    netMode = MODE_STA;
    staLostSince = 0;
    startMDNS();
    printBanner();
    return true;
  }
  Serial.println("Router connection failed");
  WiFi.disconnect(true);
  delay(200);
  return false;
}

void startNetwork()
{
  WiFi.persistent(false);          // we keep our own settings in Preferences
  WiFi.hostname(HOSTNAME);

  if (wantRouter && staSsid.length() > 0) {
    if (connectRouter()) {
      if (verifyPending) {                         // new settings work
        verifyPending = false; prevSsid = ""; prevPass = "";
        saveWifiSettings();
      }
    } else if (verifyPending && prevSsid.length() > 0) {
      // new router settings failed -> go back to the old ones
      Serial.println("New router settings failed - restoring the previous router");
      staSsid = prevSsid; staPass = prevPass;
      verifyPending = false; prevSsid = ""; prevPass = "";
      saveWifiSettings();
      if (!connectRouter()) startHotspot(true);
    } else {
      startHotspot(true);                          // backup hotspot, keeps retrying
    }
  } else {
    startHotspot(false);
  }
  udp.begin(DISCOVERY_PORT);
}

// Called from loop(): keeps router mode alive, falls back to hotspot
void maintainNetwork()
{
  unsigned long now = millis();

  if (netMode == MODE_STA) {
    if (WiFi.status() == WL_CONNECTED) {
      staLostSince = 0;
    } else {
      if (staLostSince == 0) staLostSince = now;
      if (now - staLostSince > STA_LOST_TO_AP_MS) {
        Serial.println("Router lost for 60 s - starting backup hotspot");
        startHotspot(true);
      }
    }
  }
  else if (netMode == MODE_AP_FALLBACK) {
    if (!retrying) {
      // retry only when nobody is using the hotspot
      if (now - lastRetryAt > STA_RETRY_INTERVAL_MS && WiFi.softAPgetStationNum() == 0) {
        Serial.println("Retrying router...");
        WiFi.begin(staSsid.c_str(), staPass.c_str());
        retrying = true;
        retryStartedAt = now;
      }
    } else if (WiFi.status() == WL_CONNECTED) {
      Serial.println("Router is back - hotspot OFF");
      WiFi.softAPdisconnect(true);
      WiFi.mode(WIFI_STA);
      netMode = MODE_STA;
      staLostSince = 0;
      retrying = false;
      startMDNS();
      printBanner();
    } else if (now - retryStartedAt > STA_CONNECT_TIMEOUT_MS) {
      WiFi.disconnect(false);
      retrying = false;
      lastRetryAt = now;
    }
  }
}



// ============================================================
//  JSON content
// ============================================================
void fillInfo(JsonDocument &doc)
{
  bool sta = (WiFi.status() == WL_CONNECTED);
  doc["device"]      = "SmartHome-ESP32";   // same id -> the app finds it
  doc["chip"]        = "ESP8266";
  doc["name"]        = AP_SSID;
  doc["fw"]          = FW_VERSION;
  doc["mac"]         = WiFi.macAddress();
  doc["mode"]        = modeName();
  doc["ip"]          = currentIP();
  doc["ap_ssid"]     = AP_SSID;
  doc["ap_secured"]  = apPass.length() >= 8;
  doc["ap_ip"]       = (netMode != MODE_STA) ? WiFi.softAPIP().toString() : "";
  doc["router_ssid"] = staSsid;
  doc["router_ip"]   = sta ? WiFi.localIP().toString() : "";
  doc["rssi"]        = sta ? WiFi.RSSI() : 0;
  doc["lamps"]       = NUM_LAMPS;
  doc["max_timer_min"] = MAX_TIMER_MINUTES;
  doc["uptime"]      = millis() / 1000;
  doc["key"]         = deviceKey;
  doc["mqtt_enabled"]   = mqttEnabled;
  doc["mqtt_host"]      = mqttHost;
  doc["mqtt_port"]      = mqttPort;
  doc["mqtt_connected"] = mqtt.connected();
}

void fillStatus(JsonDocument &doc)
{
  JsonArray arr = doc["lamps"].to<JsonArray>();
  for (int i = 0; i < NUM_LAMPS; i++) {
    JsonObject o = arr.add<JsonObject>();
    o["id"]    = i + 1;
    o["name"]  = lampName[i];
    o["on"]    = lampState[i];
    o["timer"] = timerRemainingSec(i);        // seconds left, 0 = no timer
  }
  doc["mode"]   = modeName();
  doc["ip"]     = currentIP();
  doc["uptime"] = millis() / 1000;
}

void fillBackup(JsonDocument &doc)
{
  doc["format"]  = "smarthome-backup";
  doc["version"] = 1;
  doc["fw"]      = FW_VERSION;
  JsonArray arr = doc["lamps"].to<JsonArray>();
  for (int i = 0; i < NUM_LAMPS; i++) {
    JsonObject o = arr.add<JsonObject>();
    o["id"]   = i + 1;
    o["name"] = lampName[i];
    o["on"]   = lampState[i];
  }
}

void fillMqtt(JsonDocument &doc)
{
  doc["enabled"]   = mqttEnabled;
  doc["host"]      = mqttHost;
  doc["port"]      = mqttPort;
  doc["user"]      = mqttUser;
  doc["key"]       = deviceKey;
  doc["topic"]     = String(MQTT_TOPIC_ROOT) + "/" + deviceKey;
  doc["connected"] = mqtt.connected();
}

void scheduleRestart(unsigned long ms)
{
  if (statesDirty) saveStatesNow();
  restartPending = true;
  restartAt      = millis() + ms;
}

// ============================================================
//  ONE command handler for HTTP and MQTT
//  returns 200 on success, 400 on bad input
// ============================================================
int fail(JsonDocument &out, const char *msg)
{
  out["ok"]    = false;
  out["error"] = msg;
  return 400;
}

int lampIndexArg(JsonVariantConst a)
{
  long n = aInt(a, "id", 0);
  return (n >= 1 && n <= NUM_LAMPS) ? (int)n - 1 : -1;
}

int cmdWifiSet(JsonVariantConst a, JsonDocument &out)
{
  String mode = aStr(a, "mode");
  mode.toLowerCase();
  if (mode != "hotspot" && mode != "router") return fail(out, "mode must be hotspot or router");

  String newApPass = apPass;
  if (aHas(a, "ap_pass")) {
    newApPass = aStr(a, "ap_pass");
    if (newApPass.length() > 0 && (newApPass.length() < 8 || newApPass.length() > 63))
      return fail(out, "hotspot password must be 8-63 characters (or empty = open)");
  }

  String newSsid = staSsid, newPass = staPass;
  if (mode == "router") {
    newSsid = aStr(a, "ssid");
    newSsid.trim();
    if (newSsid.length() < 1 || newSsid.length() > 32) return fail(out, "router SSID is required (1-32 chars)");
    if (aHas(a, "pass")) newPass = aStr(a, "pass");
    else if (newSsid != staSsid) newPass = "";
    if (newPass.length() > 63) return fail(out, "router password too long");
  }

  // working router + changed router settings -> keep the old ones as backup
  bool routerChanged = (mode == "router") && (newSsid != staSsid || newPass != staPass);
  if (routerChanged && netMode == MODE_STA && WiFi.status() == WL_CONNECTED) {
    prevSsid = staSsid; prevPass = staPass; verifyPending = true;
  } else if (mode == "hotspot") {
    verifyPending = false; prevSsid = ""; prevPass = "";
  }

  apPass     = newApPass;
  staSsid    = newSsid;
  staPass    = newPass;
  wantRouter = (mode == "router");
  saveWifiSettings();

  out["ok"]         = true;
  out["restarting"] = true;
  out["mode"]       = mode;
  out["rollback"]   = verifyPending;   // old router is restored if the new one fails
  scheduleRestart(1500);
  return 200;
}

int cmdMqttSet(JsonVariantConst a, JsonDocument &out)
{
  if (aHas(a, "host")) {
    String h = aStr(a, "host");
    h.trim();
    if (h.length() < 3 || h.length() > 100) return fail(out, "broker host is not valid");
    mqttHost = h;
  }
  if (aHas(a, "port")) {
    long p = aInt(a, "port", 0);
    if (p < 1 || p > 65535) return fail(out, "port must be 1-65535");
    mqttPort = (uint16_t)p;
  }
  if (aHas(a, "enabled")) mqttEnabled = aBool(a, "enabled", true);
  if (aHas(a, "user"))    mqttUser = aStr(a, "user");
  if (aHas(a, "pass"))    mqttPass = aStr(a, "pass");
  if (aBool(a, "new_key", false)) deviceKey = makeKey();
  saveMqttSettings();
  mqttReconnectPending = true;      // reconnect after the reply is sent

  out["ok"] = true;
  fillMqtt(out);
  return 200;
}

int cmdImport(JsonVariantConst a, JsonDocument &out)
{
  JsonVariantConst data = a["data"].isNull() ? a : a["data"];
  JsonArrayConst arr = data["lamps"].as<JsonArrayConst>();
  if (arr.isNull()) return fail(out, "JSON has no 'lamps' list");

  bool doNames  = aBool(a, "names", true);
  bool doStates = aBool(a, "states", true);
  int  changed  = 0;

  for (JsonObjectConst o : arr) {
    int id = o["id"] | 0;
    if (id < 1 || id > NUM_LAMPS) continue;
    int i = id - 1;
    if (doNames && o["name"].is<const char *>()) {
      lampName[i] = cleanName(String(o["name"].as<const char *>()), i);
      saveName(i);
    }
    if (doStates && o["on"].is<bool>()) setLamp(i, o["on"].as<bool>());
    changed++;
  }
  if (changed == 0) return fail(out, "no valid lamps in JSON");
  out["ok"] = true;
  fillStatus(out);
  return 200;
}

int cmdScan(JsonDocument &out)
{
  int n = WiFi.scanNetworks();
  out["ok"] = true;
  JsonArray arr = out["networks"].to<JsonArray>();
  int total = n > 64 ? 64 : (n < 0 ? 0 : n);
  bool used[64] = {false};
  for (int k = 0; k < total && arr.size() < 20; k++) {     // strongest first, max 20
    int best = -1;
    for (int j = 0; j < total; j++)
      if (!used[j] && (best < 0 || WiFi.RSSI(j) > WiFi.RSSI(best))) best = j;
    used[best] = true;
    String ssid = WiFi.SSID(best);
    if (ssid.length() == 0) continue;
    bool dup = false;
    for (JsonObject o : arr) if (o["ssid"] == ssid) { dup = true; break; }
    if (dup) continue;
    JsonObject o = arr.add<JsonObject>();
    o["ssid"]   = ssid;
    o["rssi"]   = WiFi.RSSI(best);
    o["secure"] = WiFi.encryptionType(best) != ENC_TYPE_NONE;
  }
  WiFi.scanDelete();
  return 200;
}

int runCommand(String cmd, JsonVariantConst a, JsonDocument &out)
{
  cmd.toLowerCase();

  if (cmd == "status") { out["ok"] = true; fillStatus(out); return 200; }
  if (cmd == "info")   { out["ok"] = true; fillInfo(out);   return 200; }

  if (cmd == "lamp") {              // id, state=on|off|toggle, timer=minutes
    int i = lampIndexArg(a);
    if (i < 0) return fail(out, "lamp id is not valid");
    if (aHas(a, "state")) {
      String s = aStr(a, "state");
      s.toLowerCase();
      if      (s == "on"  || s == "1" || s == "true")  setLamp(i, true);
      else if (s == "off" || s == "0" || s == "false") setLamp(i, false);
      else if (s == "toggle")                          setLamp(i, !lampState[i]);
      else return fail(out, "state must be on, off or toggle");
    }
    if (aHas(a, "timer")) {
      long m = aInt(a, "timer");
      if (m > 0) startTimer(i, m); else cancelTimer(i);
    }
    out["ok"] = true; fillStatus(out); return 200;
  }

  if (cmd == "all") {
    String s = aStr(a, "state");
    s.toLowerCase();
    if (s != "on" && s != "off") return fail(out, "state must be on or off");
    for (int i = 0; i < NUM_LAMPS; i++) setLamp(i, s == "on");
    out["ok"] = true; fillStatus(out); return 200;
  }

  if (cmd == "timer") {             // id, minutes (0 = cancel)
    int i = lampIndexArg(a);
    if (i < 0) return fail(out, "lamp id is not valid");
    long m = aInt(a, "minutes");
    if (m > 0) startTimer(i, m); else cancelTimer(i);
    out["ok"] = true; fillStatus(out); return 200;
  }

  if (cmd == "name") {              // id, name
    int i = lampIndexArg(a);
    if (i < 0) return fail(out, "lamp id is not valid");
    lampName[i] = cleanName(aStr(a, "name"), i);
    saveName(i);
    out["ok"] = true; fillStatus(out); return 200;
  }

  if (cmd == "export") { out["ok"] = true; fillBackup(out); return 200; }
  if (cmd == "import") return cmdImport(a, out);

  if (cmd == "wifi_get") {
    out["ok"]          = true;
    out["router"]      = wantRouter;
    out["router_ssid"] = staSsid;
    out["ap_ssid"]     = AP_SSID;
    out["ap_secured"]  = apPass.length() >= 8;
    out["mode"]        = modeName();
    out["ip"]          = currentIP();
    return 200;
  }
  if (cmd == "wifi_set") return cmdWifiSet(a, out);
  if (cmd == "scan")     return cmdScan(out);

  if (cmd == "mqtt_get") { out["ok"] = true; fillMqtt(out); return 200; }
  if (cmd == "mqtt_set") return cmdMqttSet(a, out);

  if (cmd == "reboot") {
    out["ok"] = true; out["restarting"] = true;
    scheduleRestart(1500);
    return 200;
  }
  if (cmd == "reset_wifi") {
    clearWifiSettings();
    out["ok"] = true; out["restarting"] = true;
    scheduleRestart(1500);
    return 200;
  }
  return fail(out, "unknown command");
}

// ============================================================
//  HTTP side
// ============================================================
void sendJson(JsonDocument &doc, int code = 200)
{
  String out;
  serializeJson(doc, out);
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Cache-Control", "no-store");
  server.send(code, "application/json", out);
}

// all URL / form arguments -> JSON object -> runCommand
void httpCommand(const char *cmd, bool jsonBody = false)
{
  JsonDocument args;
  if (jsonBody) {
    if (deserializeJson(args, server.arg("plain"))) {
      JsonDocument err;
      fail(err, "invalid JSON");
      sendJson(err, 400);
      return;
    }
  }
  for (int i = 0; i < server.args(); i++) {
    String n = server.argName(i);
    if (n == "plain") continue;
    args[n] = server.arg(i);
  }
  JsonDocument out;
  int code = runCommand(cmd, args, out);
  if (String(cmd) == "export")
    server.sendHeader("Content-Disposition", "attachment; filename=\"smarthome-backup.json\"");
  sendJson(out, code);
}

void apiInfo()      { httpCommand("info"); }
void apiStatus()    { httpCommand("status"); }
void apiLamp()      { httpCommand("lamp"); }
void apiAll()       { httpCommand("all"); }
void apiTimer()     { httpCommand("timer"); }
void apiName()      { httpCommand("name"); }
void apiExport()    { httpCommand("export"); }
void apiImport()    { httpCommand("import", true); }
void apiWifiGet()   { httpCommand("wifi_get"); }
void apiWifiSet()   { httpCommand("wifi_set"); }
void apiScan()      { httpCommand("scan"); }
void apiMqttGet()   { httpCommand("mqtt_get"); }
void apiMqttSet()   { httpCommand("mqtt_set"); }
void apiReboot()    { httpCommand("reboot"); }
void apiResetWifi() { httpCommand("reset_wifi"); }

void apiOptions()
{
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
  server.send(204);
}

// ============================================================
//  Browser pages
// ============================================================
String htmlEscape(const String &s)
{
  String o;
  o.reserve(s.length() + 8);
  for (unsigned int k = 0; k < s.length(); k++) {
    char c = s[k];
    if      (c == '<')  o += "&lt;";
    else if (c == '>')  o += "&gt;";
    else if (c == '&')  o += "&amp;";
    else if (c == '\'') o += "&#39;";
    else if (c == '"')  o += "&quot;";
    else o += c;
  }
  return o;
}

// Build the web page with 15 lamps (same look as v1, plus IP info, names & timers)
String buildPage()
{
  String p;
  p.reserve(6000);
  p += F("<!DOCTYPE html><html><head><meta charset='utf-8'>"
         "<meta name='viewport' content='width=device-width,initial-scale=1'>"
         "<title>Smart Home</title><style>"
         "body{font-family:Arial,sans-serif;background:#f2f4f7;margin:0;padding:16px;text-align:center}"
         "h2{margin:8px 0 12px}"
         ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;max-width:900px;margin:auto}"
         ".card{background:#fff;border-radius:10px;padding:12px;box-shadow:0 1px 4px rgba(0,0,0,.15)}"
         ".card.on{border-top:5px solid #22a559}.card.off{border-top:5px solid #c9ced6}"
         ".name{font-weight:bold;margin-bottom:8px}.tm{font-size:12px;color:#c77700;margin:-4px 0 6px}"
         "a{display:inline-block;width:44%;padding:10px 0;margin:2px;border-radius:6px;color:#fff;text-decoration:none;font-weight:bold}"
         ".b1{background:#22a559}.b0{background:#d64545}.bs{background:#4b5bd6}"
         ".all{max-width:900px;margin:16px auto 0}.all a{width:auto;padding:10px 20px}"
         ".info{max-width:900px;margin:0 auto 12px;background:linear-gradient(135deg,#6c4df5,#e0457b);color:#fff;"
         "border-radius:10px;padding:10px;display:flex;flex-wrap:wrap;gap:8px;justify-content:center}"
         ".info span{background:rgba(255,255,255,.2);border-radius:14px;padding:4px 10px;font-size:14px}"
         ".warn{max-width:900px;margin:0 auto 12px;background:#fff4d6;border:1px solid #f0c040;border-radius:8px;padding:8px}"
         "</style></head><body><h2>Smart Home - Lamp Control</h2><div class='info'>");

  // ---- IP / mode / cloud info bar ----
  p += "<span>Mode: <b>";
  p += (netMode == MODE_STA) ? "Router" : (netMode == MODE_AP_FALLBACK ? "Backup hotspot" : "Hotspot");
  p += "</b></span>";
  if (WiFi.status() == WL_CONNECTED) {
    p += "<span>Router IP: <b>" + WiFi.localIP().toString() + "</b></span>";
    p += "<span>WiFi: <b>" + htmlEscape(staSsid) + "</b> (" + String(WiFi.RSSI()) + " dBm)</span>";
  }
  if (netMode != MODE_STA) p += "<span>Hotspot IP: <b>" + WiFi.softAPIP().toString() + "</b></span>";
  p += "<span>Cloud: <b>";
  p += !mqttEnabled ? "off" : (mqtt.connected() ? "connected" : (netMode == MODE_STA ? "connecting" : "router mode only"));
  p += "</b></span></div>";

  if (netMode != MODE_STA && apPass.length() < 8)
    p += F("<div class='warn'>Hotspot has no password. Open <b>Setup</b> to set one.</div>");

  p += F("<div class='grid'>");
  for (int i = 0; i < NUM_LAMPS; i++) {
    int n = i + 1;
    p += "<div class='card ";
    p += lampState[i] ? "on" : "off";
    p += "'><div class='name'>";
    p += htmlEscape(lampName[i]);
    p += lampState[i] ? " (ON)" : " (OFF)";
    p += "</div>";
    long rem = timerRemainingSec(i);
    if (rem > 0) {
      p += "<div class='tm'>OFF in ";
      p += String((rem + 59) / 60);
      p += " min</div>";
    }
    p += "<a class='b1' href='/Lamp_";
    p += n;
    p += "_ON'>ON</a><a class='b0' href='/Lamp_";
    p += n;
    p += "_OFF'>OFF</a></div>";
  }

  p += F("</div><div class='all'><a class='b1' href='/All_ON'>ALL ON</a> "
         "<a class='b0' href='/All_OFF'>ALL OFF</a> "
         "<a class='bs' href='/setup'>Setup</a></div></body></html>");
  return p;
}

// WiFi + cloud setup page for browsers (the app has its own screens)
const char SETUP_PAGE[] PROGMEM = R"HTML(<!DOCTYPE html><html><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'><title>Smart Home - Setup</title>
<style>body{font-family:Arial,sans-serif;background:#f2f4f7;margin:0;padding:16px}
.box{max-width:460px;margin:0 auto 14px;background:#fff;border-radius:12px;padding:16px;box-shadow:0 1px 4px rgba(0,0,0,.15)}
h2{text-align:center;margin-top:0}label{display:block;margin:12px 0 4px;font-weight:bold}
input{width:100%;padding:10px;border:1px solid #c9ced6;border-radius:6px;box-sizing:border-box;font-size:15px}
.r{display:flex;gap:8px}.r label{flex:1;font-weight:normal;border:1px solid #c9ced6;border-radius:8px;padding:10px;margin:0}
.r input,.cb{width:auto}button{width:100%;padding:12px;margin-top:16px;border:0;border-radius:8px;color:#fff;font-weight:bold;font-size:15px}
.save{background:#22a559}.scan{background:#4b5bd6;margin-top:8px}.back{background:#7a8290}
.msg{margin-top:12px;text-align:center;font-weight:bold}.hint{font-size:12px;color:#666}
.kv{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #eee}.kv b{word-break:break-all}
.key{font-family:monospace;font-size:20px;text-align:center;background:#f2f0ff;border-radius:8px;padding:8px;letter-spacing:2px}</style></head><body>
<div class='box'><h2>Device</h2><div id='inf'>Loading...</div></div>
<div class='box'><h2>WiFi Setup</h2>
<div class='r'><label><input type='radio' name='mode' value='hotspot' checked onchange='upd()'> Hotspot</label>
<label><input type='radio' name='mode' value='router' onchange='upd()'> Router</label></div>
<div id='rt' style='display:none'><label>Router WiFi name (SSID)</label><input id='ssid' list='nets'>
<datalist id='nets'></datalist><button class='scan' onclick='scan()'>Scan networks</button>
<label>Router password</label><input id='pass' type='password' placeholder='empty = keep saved password'></div>
<label>Hotspot password</label><input id='ap' type='password' placeholder='leave empty = no change'>
<div class='hint'>8-63 characters. <input type='checkbox' id='open' class='cb'> remove password (open hotspot)</div>
<button class='save' onclick='saveWifi()'>Save &amp; Restart</button><div class='msg' id='m1'></div>
<div class='hint'>After the restart in Router mode, the new IP is shown in the app (local or cloud), on the
Serial Monitor, and at http://smarthome.local (PC).</div></div>
<div class='box'><h2>Cloud (MQTT)</h2><div class='hint'>Control from any network. Works in Router mode only.</div>
<label>Secret key (enter this in the app)</label><div class='key' id='key'>-</div>
<label><input type='checkbox' id='men' class='cb'> Cloud enabled</label>
<label>Broker</label><input id='mh'><label>Port</label><input id='mp' type='number'>
<button class='save' onclick='saveMqtt(false)'>Save cloud settings</button>
<button class='back' onclick='if(confirm("Make a new key? Phones must pair again."))saveMqtt(true)'>New secret key</button>
<div class='msg' id='m2'></div></div>
<div class='box'><button class='back' onclick='location="/"'>Back to lamps</button></div>
<script>
function $(i){return document.getElementById(i)}
function m(){return document.querySelector('input[name=mode]:checked').value}
function upd(){$('rt').style.display=m()=='router'?'block':'none'}
function kv(k,v){return "<div class='kv'><span>"+k+"</span><b>"+(v||'-')+"</b></div>"}
function load(){fetch('/api/info').then(r=>r.json()).then(j=>{
$('inf').innerHTML=kv('Mode',j.mode)+kv('Router IP',j.router_ip)+kv('Router WiFi',j.router_ssid)+kv('Hotspot IP',j.ap_ip)+
kv('Hotspot password',j.ap_secured?'yes':'NO (open)')+kv('Cloud',j.mqtt_enabled?(j.mqtt_connected?'connected':'not connected'):'off')+
kv('Firmware',j.fw)+kv('MAC',j.mac);
$('key').textContent=j.key;$('men').checked=j.mqtt_enabled;$('mh').value=j.mqtt_host;$('mp').value=j.mqtt_port;
if(j.mode!='hotspot'){document.querySelector('input[value=router]').checked=true;upd()}$('ssid').value=j.router_ssid||''})}
load();
function scan(){$('m1').textContent='Scanning...';fetch('/api/scan').then(r=>r.json()).then(j=>{var d=$('nets');d.innerHTML='';
j.networks.forEach(n=>{var o=document.createElement('option');o.value=n.ssid;d.appendChild(o)});$('m1').textContent=j.networks.length+' networks found'})}
function post(u,f,el){fetch(u,{method:'POST',body:f}).then(r=>r.json()).then(j=>{$(el).textContent=j.ok?'Saved':j.error;if(j.ok&&el=='m2')setTimeout(load,3000);
if(j.ok&&j.restarting)$(el).textContent='Saved. Device is restarting...'}).catch(e=>$(el).textContent='Error: '+e)}
function saveWifi(){var f=new URLSearchParams();f.append('mode',m());
if($('open').checked)f.append('ap_pass','');else if($('ap').value)f.append('ap_pass',$('ap').value);
if(m()=='router'){f.append('ssid',$('ssid').value);if($('pass').value)f.append('pass',$('pass').value)}post('/api/wifi',f,'m1')}
function saveMqtt(nk){var f=new URLSearchParams();f.append('enabled',$('men').checked?'1':'0');f.append('host',$('mh').value);
f.append('port',$('mp').value);if(nk)f.append('new_key','1');post('/api/mqtt',f,'m2')}
</script></body></html>)HTML";

void handleSetupPage() { server.send_P(200, "text/html", SETUP_PAGE); }

// ------------------------------------------------------------
// Old URLs (v1 / MIT App Inventor): /Lamp_N_ON , /Lamp_N_OFF , /All_ON , /All_OFF
// Any other unknown URL shows the lamp page.
void handleRequest()
{
  String uri = server.uri();   // e.g. "/Lamp_10_ON"

  if (uri == "/All_ON") {
    for (int i = 0; i < NUM_LAMPS; i++) setLamp(i, true);
  }
  else if (uri == "/All_OFF") {
    for (int i = 0; i < NUM_LAMPS; i++) setLamp(i, false);
  }
  else if (uri.startsWith("/Lamp_")) {
    int us = uri.indexOf('_', 6);                    // underscore after the number
    if (us > 6) {
      int n = uri.substring(6, us).toInt();          // lamp number 1..15
      String cmd = uri.substring(us + 1);            // "ON" or "OFF"
      if (n >= 1 && n <= NUM_LAMPS) {
        if (cmd == "ON")  setLamp(n - 1, true);
        if (cmd == "OFF") setLamp(n - 1, false);
      }
    }
  }
  else if (uri == "/favicon.ico") {
    server.send(204);
    return;
  }
  else if (uri.startsWith("/api/")) {
    if (server.method() == HTTP_OPTIONS) { apiOptions(); return; }
    JsonDocument err;
    fail(err, "unknown API");
    sendJson(err, 404);
    return;
  }

  server.send(200, "text/html", buildPage());
}

// ============================================================
//  MQTT (cloud)
//    smarthome/<key>/cmd           <- JSON command  {"req":"x1","cmd":"lamp","id":3,"state":"on"}
//    smarthome/<key>/reply         -> JSON reply    {"req":"x1","cmd":"lamp","ok":true,...}
//    smarthome/<key>/status        -> lamps + IP (retained)
//    smarthome/<key>/online        -> "online" / "offline" (retained, last will)
//    smarthome/<key>/lamp/3/set    <- ON / OFF / TOGGLE     (for MQTT dashboard apps)
//    smarthome/<key>/lamp/3/state  -> ON / OFF (retained)
// ============================================================
void mqttCallback(char *topic, byte *payload, unsigned int len)
{
  if (qCount >= MQTT_QUEUE) return;           // busy - drop
  int idx = (qHead + qCount) % MQTT_QUEUE;
  qTopic[idx] = topic;
  qPayload[idx] = "";
  qPayload[idx].reserve(len + 1);
  for (unsigned int i = 0; i < len; i++) qPayload[idx] += (char)payload[i];
  qCount++;
}

void mqttPublish(const String &topic, const String &payload, bool retained)
{
  if (!mqtt.connected()) return;
  mqtt.publish(topic.c_str(), (const uint8_t *)payload.c_str(), payload.length(), retained);
}

void publishStatus()
{
  JsonDocument doc;
  fillStatus(doc);
  doc["online"]      = true;
  doc["fw"]          = FW_VERSION;
  doc["router_ssid"] = staSsid;
  doc["rssi"]        = WiFi.RSSI();
  doc["ap_secured"]  = apPass.length() >= 8;
  String out;
  serializeJson(doc, out);
  mqttPublish(mqttBase + "/status", out, true);

  // simple per-lamp state topics (only changed ones)
  for (int i = 0; i < NUM_LAMPS; i++) {
    bool on = lampState[i];
    bool was = (publishedMask >> i) & 1UL;
    if (publishAllStates || on != was) {
      mqttPublish(mqttBase + "/lamp/" + String(i + 1) + "/state", on ? "ON" : "OFF", true);
      if (on) publishedMask |= (1UL << i); else publishedMask &= ~(1UL << i);
    }
  }
  publishAllStates = false;
  statusDirty      = false;
  lastStatusPubAt  = millis();
}

void handleMqttMessage(const String &topic, const String &payload)
{
  if (topic == mqttBase + "/cmd") {
    JsonDocument req;
    JsonDocument out;
    if (deserializeJson(req, payload)) {
      fail(out, "invalid JSON");
    } else {
      String cmd = aStr(req.as<JsonVariantConst>(), "cmd");
      Serial.printf("Cloud command: %s\n", cmd.c_str());
      runCommand(cmd, req.as<JsonVariantConst>(), out);
      out["cmd"] = cmd;
    }
    if (!req["req"].isNull()) out["req"] = req["req"];
    String s;
    serializeJson(out, s);
    mqttPublish(mqttBase + "/reply", s, false);
    return;
  }

  // smarthome/<key>/lamp/<n>/set
  String pre = mqttBase + "/lamp/";
  if (topic.startsWith(pre) && topic.endsWith("/set")) {
    int n = topic.substring(pre.length(), topic.length() - 4).toInt();
    if (n < 1 || n > NUM_LAMPS) return;
    String p = payload;
    p.trim();
    p.toUpperCase();
    if      (p == "ON"  || p == "1" || p == "TRUE")  setLamp(n - 1, true);
    else if (p == "OFF" || p == "0" || p == "FALSE") setLamp(n - 1, false);
    else if (p == "TOGGLE")                          setLamp(n - 1, !lampState[n - 1]);
  }
}

void mqttLoop()
{
  bool canRun = mqttEnabled && netMode == MODE_STA && WiFi.status() == WL_CONNECTED;

  if (mqttReconnectPending) {                 // settings were changed
    mqttReconnectPending = false;
    if (mqtt.connected()) {
      // clear the retained messages of the old topic (key may have changed)
      mqttPublish(mqttBase + "/status", "", true);
      mqttPublish(mqttBase + "/online", "", true);
      for (int i = 0; i < NUM_LAMPS; i++) mqttPublish(mqttBase + "/lamp/" + String(i + 1) + "/state", "", true);
      mqtt.disconnect();
    }
    mqttRetryMs = 0;
    mqttLastTry = 0;
  }

  if (!canRun) {
    if (mqtt.connected()) mqtt.disconnect();
    return;
  }

  if (!mqtt.connected()) {
    if (mqttLastTry != 0 && millis() - mqttLastTry < mqttRetryMs) return;
    mqttLastTry = millis();
    if (mqttLastTry == 0) mqttLastTry = 1;

    mqttBase = String(MQTT_TOPIC_ROOT) + "/" + deviceKey;
    String cid  = "smarthome-" + deviceKey;
    String will = mqttBase + "/online";
    mqtt.setServer(mqttHost.c_str(), mqttPort);
    Serial.printf("Cloud: connecting to %s:%u ... ", mqttHost.c_str(), mqttPort);

    bool ok;
    if (mqttUser.length() > 0)
      ok = mqtt.connect(cid.c_str(), mqttUser.c_str(), mqttPass.c_str(), will.c_str(), 1, true, "offline");
    else
      ok = mqtt.connect(cid.c_str(), will.c_str(), 1, true, "offline");

    if (ok) {
      Serial.printf("connected. Topic: %s/#\n", mqttBase.c_str());
      mqttRetryMs = 5000;
      mqtt.publish(will.c_str(), "online", true);
      mqtt.subscribe((mqttBase + "/cmd").c_str());
      mqtt.subscribe((mqttBase + "/lamp/+/set").c_str());
      publishAllStates = true;
      publishStatus();
    } else {
      mqttRetryMs = (mqttRetryMs == 0) ? 5000UL : ((mqttRetryMs * 2 > 60000UL) ? 60000UL : mqttRetryMs * 2);
      Serial.printf("failed (state %d), retry in %lu s\n", mqtt.state(), mqttRetryMs / 1000);
    }
    return;
  }

  mqtt.loop();

  while (qCount > 0) {
    String t = qTopic[qHead], p = qPayload[qHead];
    qTopic[qHead] = ""; qPayload[qHead] = "";
    qHead = (qHead + 1) % MQTT_QUEUE;
    qCount--;
    handleMqttMessage(t, p);
  }

  unsigned long now = millis();
  if ((statusDirty && now - statusDirtyAt > STATUS_PUBLISH_DELAY_MS) ||
      now - lastStatusPubAt > STATUS_REFRESH_MS)
    publishStatus();
}

// ============================================================
//  UDP discovery: app sends "SMARTHOME_DISCOVER", we answer with info JSON
// ============================================================
void handleDiscovery()
{
  int len = udp.parsePacket();
  if (len <= 0) return;
  char buf[40];
  int n = udp.read(buf, sizeof(buf) - 1);
  if (n < 0) n = 0;
  buf[n] = 0;
  if (strncmp(buf, "SMARTHOME_DISCOVER", 18) != 0) return;

  JsonDocument doc;
  fillInfo(doc);
  String out;
  serializeJson(doc, out);
  udp.beginPacket(udp.remoteIP(), udp.remotePort());
  udp.print(out);
  udp.endPacket();
}

// ============================================================
void setup()
{
  Serial.begin(115200, SERIAL_8N1, SERIAL_TX_ONLY);   // RX pin = reset button
  delay(100);
  Serial.println();
  Serial.println("Smart Home ESP8266  v" FW_VERSION);
  if (!LittleFS.begin()) { LittleFS.format(); LittleFS.begin(); }

  initLamps();                         // lamps back to state before power cut

  loadWifiSettings();
  loadMqttSettings();
  checkResetButton();                  // GPIO14 held 5 s -> WiFi reset
  startNetwork();

  mqtt.setBufferSize(MQTT_BUFFER_SIZE);
  mqtt.setKeepAlive(30);
  mqtt.setSocketTimeout(5);
  mqtt.setCallback(mqttCallback);

  server.on("/api/info",       HTTP_GET,  apiInfo);
  server.on("/api/status",     HTTP_GET,  apiStatus);
  server.on("/api/lamp",       HTTP_ANY,  apiLamp);
  server.on("/api/all",        HTTP_ANY,  apiAll);
  server.on("/api/timer",      HTTP_ANY,  apiTimer);
  server.on("/api/name",       HTTP_POST, apiName);
  server.on("/api/export",     HTTP_GET,  apiExport);
  server.on("/api/import",     HTTP_POST, apiImport);
  server.on("/api/wifi",       HTTP_GET,  apiWifiGet);
  server.on("/api/wifi",       HTTP_POST, apiWifiSet);
  server.on("/api/scan",       HTTP_GET,  apiScan);
  server.on("/api/mqtt",       HTTP_GET,  apiMqttGet);
  server.on("/api/mqtt",       HTTP_POST, apiMqttSet);
  server.on("/api/reboot",     HTTP_POST, apiReboot);
  server.on("/api/reset_wifi", HTTP_POST, apiResetWifi);
  server.on("/setup",          HTTP_GET,  handleSetupPage);
  server.onNotFound(handleRequest);    // "/", old URLs, everything else
  server.begin();
  Serial.println("Web server started");
}

// ------------------------------------------------------------
void loop()
{
  server.handleClient();
  handleDiscovery();
  checkTimers();
  maintainNetwork();
  mqttLoop();
  MDNS.update();

  if (statesDirty && millis() - statesDirtyAt > STATE_SAVE_DELAY_MS) saveStatesNow();

  if (restartPending && (long)(millis() - restartAt) >= 0) {
    if (mqtt.connected()) {
      mqtt.publish((mqttBase + "/online").c_str(), "offline", true);
      mqtt.disconnect();
    }
    Serial.println("Restarting...");
    delay(100);
    ESP.restart();
  }
  delay(2);
}
