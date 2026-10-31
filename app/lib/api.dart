import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything the screens need from the device.
/// Two ways to reach it: [HttpDeviceApi] (same WiFi) and MqttDeviceApi (cloud).
abstract class DeviceApi {
  /// IP address, or "cloud".
  String get host;
  bool get isCloud;

  /// Fires when the device sends new data by itself (cloud). HTTP: never.
  Stream<void> get changes;

  /// Latest device IP / mode seen in any status reply.
  String? lastIp;
  String? lastMode;

  /// Device clock (for schedules): synced from the internet in Router mode.
  bool lastTimeOk = false;
  String lastTime = '';

  List<Lamp> parseLamps(Map<String, dynamic> j) {
    if (j['ip'] is String && (j['ip'] as String).isNotEmpty) lastIp = j['ip'] as String;
    if (j['mode'] is String) lastMode = j['mode'] as String;
    if (j.containsKey('time_ok')) {
      lastTimeOk = j['time_ok'] == true;
      lastTime = j['time'] is String ? j['time'] as String : '';
    }
    return Lamp.listFromJson(j);
  }

  Future<DeviceInfo> info({Duration? timeout});
  Future<List<Lamp>> status();
  Future<List<Lamp>> setLamp(int id, bool on);

  /// Turns the lamp ON and switches it OFF after [minutes]. 0 = cancel timer.
  Future<List<Lamp>> setTimer(int id, int minutes);
  Future<List<Lamp>> setAll(bool on);
  Future<List<Lamp>> rename(int id, String name);

  /// Daily schedule for one lamp. [onMin] / [offMin] = minutes after midnight.
  Future<List<Lamp>> setSchedule(int id, {required bool enabled, required int onMin, required int offMin});

  Future<String> exportJson();
  Future<List<Lamp>> importJson(String json, {bool names = true, bool states = true});

  Future<WifiSettings> wifi();
  Future<List<WifiNetwork>> scan();

  /// [pass] null = keep the saved router password (same SSID).
  /// [apPass] null = keep, "" = open hotspot, else 8..63 chars.
  Future<bool> saveWifi({required bool router, String? ssid, String? pass, String? apPass});

  Future<MqttSettings> mqtt();
  Future<MqttSettings> saveMqtt({
    bool? enabled,
    String? host,
    int? port,
    String? user,
    String? pass,
    bool newKey = false,
  });

  Future<void> reboot();
  Future<void> resetWifi();
  void close();

  static String pretty(Map<String, dynamic> j) => const JsonEncoder.withIndent('  ').convert(j);

  static Map<String, dynamic> backupOnly(Map<String, dynamic> j) =>
      Map<String, dynamic>.from(j)..removeWhere((k, _) => k == 'ok' || k == 'req' || k == 'cmd');
}

/// Local network: talks to http://<ip>/api/...
class HttpDeviceApi extends DeviceApi {
  HttpDeviceApi(this.host);

  @override
  final String host;
  @override
  bool get isCloud => false;
  @override
  Stream<void> get changes => const Stream<void>.empty();

  final http.Client _client = http.Client();
  static const Duration _timeout = Duration(seconds: 6);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: host, path: path, queryParameters: query);

  Map<String, dynamic> _decode(http.Response r) {
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw ApiException('Unexpected reply from device (HTTP ${r.statusCode})');
    }
    if (j is! Map<String, dynamic>) throw ApiException('Unexpected reply from device');
    if (r.statusCode != 200 || j['ok'] == false) {
      throw ApiException('${j['error'] ?? 'HTTP ${r.statusCode}'}');
    }
    return j;
  }

  Future<Map<String, dynamic>> _run(Future<http.Response> Function() call,
      [Duration? timeout]) async {
    try {
      final r = await call().timeout(timeout ?? _timeout);
      return _decode(r);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('Device not responding ($host)');
    } catch (_) {
      throw ApiException('Cannot reach device ($host)');
    }
  }

  Future<Map<String, dynamic>> _get(String path,
          [Map<String, String>? query, Duration? timeout]) =>
      _run(() => _client.get(_uri(path, query)), timeout);

  Future<Map<String, dynamic>> _postForm(String path, Map<String, String> body) =>
      _run(() => _client.post(_uri(path), body: body));

  @override
  Future<DeviceInfo> info({Duration? timeout}) async {
    final j = await _get('/api/info', null, timeout);
    parseLamps(j);
    return DeviceInfo.fromJson(j, host);
  }

  @override
  Future<List<Lamp>> status() async => parseLamps(await _get('/api/status'));

  @override
  Future<List<Lamp>> setLamp(int id, bool on) async =>
      parseLamps(await _get('/api/lamp', {'id': '$id', 'state': on ? 'on' : 'off'}));

  @override
  Future<List<Lamp>> setTimer(int id, int minutes) async =>
      parseLamps(await _get('/api/timer', {'id': '$id', 'minutes': '$minutes'}));

  @override
  Future<List<Lamp>> setAll(bool on) async =>
      parseLamps(await _get('/api/all', {'state': on ? 'on' : 'off'}));

  @override
  Future<List<Lamp>> rename(int id, String name) async =>
      parseLamps(await _postForm('/api/name', {'id': '$id', 'name': name}));

  @override
  Future<List<Lamp>> setSchedule(int id,
          {required bool enabled, required int onMin, required int offMin}) async =>
      parseLamps(await _postForm('/api/schedule', {
        'id': '$id',
        'enabled': enabled ? '1' : '0',
        'on': formatHM(onMin),
        'off': formatHM(offMin),
      }));

  @override
  Future<String> exportJson() async =>
      DeviceApi.pretty(DeviceApi.backupOnly(await _get('/api/export')));

  @override
  Future<List<Lamp>> importJson(String json, {bool names = true, bool states = true}) async {
    final uri = _uri('/api/import', {
      if (!names) 'names': '0',
      if (!states) 'states': '0',
    });
    final j = await _run(() => _client.post(uri,
        headers: {'Content-Type': 'application/json'}, body: json));
    return parseLamps(j);
  }

  @override
  Future<WifiSettings> wifi() async => WifiSettings.fromJson(await _get('/api/wifi'));

  @override
  Future<List<WifiNetwork>> scan() async {
    final j = await _get('/api/scan', null, const Duration(seconds: 20));
    final list = j['networks'];
    if (list is! List) return [];
    return list.whereType<Map<String, dynamic>>().map(WifiNetwork.fromJson).toList();
  }

  @override
  Future<bool> saveWifi({required bool router, String? ssid, String? pass, String? apPass}) async {
    final body = <String, String>{'mode': router ? 'router' : 'hotspot'};
    if (router) {
      body['ssid'] = ssid ?? '';
      if (pass != null) body['pass'] = pass;
    }
    if (apPass != null) body['ap_pass'] = apPass;
    final j = await _postForm('/api/wifi', body);
    return j['rollback'] == true;
  }

  @override
  Future<MqttSettings> mqtt() async => MqttSettings.fromJson(await _get('/api/mqtt'));

  @override
  Future<MqttSettings> saveMqtt({
    bool? enabled,
    String? host,
    int? port,
    String? user,
    String? pass,
    bool newKey = false,
  }) async {
    final body = <String, String>{
      if (enabled != null) 'enabled': enabled ? '1' : '0',
      if (host != null) 'host': host,
      if (port != null) 'port': '$port',
      if (user != null) 'user': user,
      if (pass != null) 'pass': pass,
      if (newKey) 'new_key': '1',
    };
    return MqttSettings.fromJson(await _postForm('/api/mqtt', body));
  }

  @override
  Future<void> reboot() => _postForm('/api/reboot', {});

  @override
  Future<void> resetWifi() => _postForm('/api/reset_wifi', {});

  @override
  void close() => _client.close();
}
