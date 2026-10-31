import 'dart:convert';

/// Data classes for the ESP32 JSON API (local HTTP and cloud MQTT).

int _int(dynamic v, [int def = 0]) => v is num ? v.toInt() : (int.tryParse('$v') ?? def);
String _str(dynamic v, [String def = '']) => v == null ? def : v.toString();

int _minuteOfDay(dynamic v, int def) {
  final m = _int(v, def);
  return (m < 0 || m > 1439) ? def : m;
}

const String kDefaultBroker = 'broker.mqtt-dashboard.com';
const int kDefaultBrokerPort = 1883;

class Lamp {
  Lamp({
    required this.id,
    required this.name,
    required this.on,
    this.timer = 0,
    this.schEnabled = false,
    this.schOn = 18 * 60,
    this.schOff = 6 * 60,
  });

  final int id;
  String name;
  bool on;

  /// Seconds until the lamp turns OFF automatically (0 = no timer).
  int timer;

  /// Daily schedule: ON / OFF time in minutes after midnight (every day).
  bool schEnabled;
  int schOn;
  int schOff;

  String get scheduleText => '${formatHM(schOn)} - ${formatHM(schOff)}';

  factory Lamp.fromJson(Map<String, dynamic> j) => Lamp(
        id: _int(j['id']),
        name: _str(j['name'], 'Lamp'),
        on: j['on'] == true,
        timer: _int(j['timer']),
        schEnabled: j['sch'] == true,
        schOn: _minuteOfDay(j['sch_on'], 18 * 60),
        schOff: _minuteOfDay(j['sch_off'], 6 * 60),
      );

  static List<Lamp> listFromJson(Map<String, dynamic> j) {
    final list = j['lamps'];
    if (list is! List) return [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(Lamp.fromJson)
        .where((l) => l.id > 0)
        .toList();
  }
}

class DeviceInfo {
  DeviceInfo({
    required this.host,
    required this.name,
    required this.fw,
    required this.mac,
    required this.mode,
    required this.ip,
    required this.apSsid,
    required this.apSecured,
    required this.apIp,
    required this.routerSsid,
    required this.routerIp,
    required this.rssi,
    required this.lamps,
    required this.uptime,
    required this.key,
    required this.mqttEnabled,
    required this.mqttHost,
    required this.mqttPort,
    required this.mqttConnected,
  });

  /// IP address the app uses (or "cloud" when connected through MQTT).
  final String host;
  final String name;
  final String fw;
  final String mac;

  /// "hotspot", "router" or "hotspot_backup"
  final String mode;

  /// Device IP on its current network.
  final String ip;
  final String apSsid;
  final bool apSecured;
  final String apIp;
  final String routerSsid;
  final String routerIp;
  final int rssi;
  final int lamps;
  final int uptime;

  /// Secret cloud key (MQTT topic smarthome/<key>/...)
  final String key;
  final bool mqttEnabled;
  final String mqttHost;
  final int mqttPort;
  final bool mqttConnected;

  bool get isRouter => mode == 'router';

  String get modeLabel => modeLabelOf(mode);

  static String modeLabelOf(String mode) {
    switch (mode) {
      case 'router':
        return 'Router';
      case 'hotspot_backup':
        return 'Backup hotspot';
      default:
        return 'Hotspot';
    }
  }

  factory DeviceInfo.fromJson(Map<String, dynamic> j, String host) => DeviceInfo(
        host: host,
        name: _str(j['name'], 'Smart Home'),
        fw: _str(j['fw'], '?'),
        mac: _str(j['mac']),
        mode: _str(j['mode'], 'hotspot'),
        ip: _str(j['ip'], host),
        apSsid: _str(j['ap_ssid'], 'Smart Home'),
        apSecured: j['ap_secured'] == true,
        apIp: _str(j['ap_ip']),
        routerSsid: _str(j['router_ssid']),
        routerIp: _str(j['router_ip']),
        rssi: _int(j['rssi']),
        lamps: _int(j['lamps'], 15),
        uptime: _int(j['uptime']),
        key: _str(j['key']),
        mqttEnabled: j['mqtt_enabled'] != false,
        mqttHost: _str(j['mqtt_host'], kDefaultBroker),
        mqttPort: _int(j['mqtt_port'], kDefaultBrokerPort),
        mqttConnected: j['mqtt_connected'] == true,
      );
}

class WifiSettings {
  WifiSettings({required this.router, required this.routerSsid, required this.apSecured});

  final bool router;
  final String routerSsid;
  final bool apSecured;

  factory WifiSettings.fromJson(Map<String, dynamic> j) => WifiSettings(
        router: j['router'] == true,
        routerSsid: _str(j['router_ssid']),
        apSecured: j['ap_secured'] == true,
      );
}

class WifiNetwork {
  WifiNetwork({required this.ssid, required this.rssi, required this.secure});

  final String ssid;
  final int rssi;
  final bool secure;

  factory WifiNetwork.fromJson(Map<String, dynamic> j) => WifiNetwork(
        ssid: _str(j['ssid']),
        rssi: _int(j['rssi'], -100),
        secure: j['secure'] != false,
      );
}

/// Cloud settings on the device (GET /api/mqtt, cmd "mqtt_get").
class MqttSettings {
  MqttSettings({
    required this.enabled,
    required this.host,
    required this.port,
    required this.user,
    required this.key,
    required this.connected,
  });

  final bool enabled;
  final String host;
  final int port;
  final String user;
  final String key;
  final bool connected;

  factory MqttSettings.fromJson(Map<String, dynamic> j) => MqttSettings(
        enabled: j['enabled'] != false,
        host: _str(j['host'], kDefaultBroker),
        port: _int(j['port'], kDefaultBrokerPort),
        user: _str(j['user']),
        key: _str(j['key']),
        connected: j['connected'] == true,
      );
}

/// What the app remembers to reach a device through the cloud.
class CloudProfile {
  CloudProfile({
    required this.key,
    this.host = kDefaultBroker,
    this.port = kDefaultBrokerPort,
    this.user = '',
    this.pass = '',
  });

  final String key;
  final String host;
  final int port;
  final String user;
  final String pass;

  bool get isValid => key.length >= 8 && host.isNotEmpty;

  CloudProfile copyWith({String? key, String? host, int? port, String? user, String? pass}) =>
      CloudProfile(
        key: key ?? this.key,
        host: host ?? this.host,
        port: port ?? this.port,
        user: user ?? this.user,
        pass: pass ?? this.pass,
      );

  String toJsonString() =>
      jsonEncode({'key': key, 'host': host, 'port': port, 'user': user, 'pass': pass});

  static CloudProfile? fromJsonString(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s);
      if (j is! Map<String, dynamic>) return null;
      final p = CloudProfile(
        key: _str(j['key']),
        host: _str(j['host'], kDefaultBroker),
        port: _int(j['port'], kDefaultBrokerPort),
        user: _str(j['user']),
        pass: _str(j['pass']),
      );
      return p.isValid ? p : null;
    } catch (_) {
      return null;
    }
  }
}

/// 1110 -> "18:30"   (minutes after midnight -> HH:MM, 24 h)
String formatHM(int minutes) {
  final h = (minutes ~/ 60) % 24;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// 1110 -> "6:30 PM"
String formatHM12(int minutes) {
  final h24 = (minutes ~/ 60) % 24;
  final m = minutes % 60;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  return '$h12:${m.toString().padLeft(2, '0')} ${h24 < 12 ? 'AM' : 'PM'}';
}

/// 95 -> "01:35",  3725 -> "1:02:05"
String formatDuration(int seconds) {
  if (seconds < 0) seconds = 0;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h ${m}m';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
