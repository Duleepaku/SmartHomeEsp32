import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'api.dart';
import 'models.dart';

/// Cloud connection through an MQTT broker (default broker.mqtt-dashboard.com).
///
///   smarthome/<key>/cmd     <- {"req":"a1","cmd":"lamp","id":3,"state":"on"}
///   smarthome/<key>/reply   -> {"req":"a1","ok":true,...}
///   smarthome/<key>/status  -> lamps + IP  (retained)
///   smarthome/<key>/online  -> "online" / "offline" (retained)
class MqttDeviceApi extends DeviceApi {
  MqttDeviceApi(this.profile);

  final CloudProfile profile;

  @override
  String get host => 'cloud';
  @override
  bool get isCloud => true;
  @override
  Stream<void> get changes => _changes.stream;

  String get base => 'smarthome/${profile.key}';

  MqttServerClient? _client;
  final _changes = StreamController<void>.broadcast();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _rnd = Random();

  Map<String, dynamic>? _status;
  DateTime _statusAt = DateTime.now();
  bool _online = false;
  bool _brokerConnected = false;
  final _firstStatus = Completer<void>();
  final _firstOnline = Completer<void>();

  bool get deviceOnline => _online;
  bool get brokerConnected => _brokerConnected;

  String _id() => List.generate(8, (_) => 'abcdefghijkmnpqrstuvwxyz23456789'[_rnd.nextInt(32)]).join();

  /// Connects to the broker and waits until the device status arrives.
  /// Throws [ApiException] if the broker or the device cannot be reached.
  Future<void> connect({Duration wait = const Duration(seconds: 6)}) async {
    final cid = 'shapp-${_id()}';
    final c = MqttServerClient.withPort(profile.host, cid, profile.port);
    _client = c;
    c.logging(on: false);
    c.keepAlivePeriod = 30;
    c.autoReconnect = true;
    c.resubscribeOnAutoReconnect = true;
    c.onConnected = () => _brokerConnected = true;
    c.onAutoReconnected = () {
      _brokerConnected = true;
      _changes.add(null);
    };
    c.onDisconnected = () {
      _brokerConnected = false;
      _changes.add(null);
    };
    c.connectionMessage = MqttConnectMessage().withClientIdentifier(cid).startClean();

    try {
      await c
          .connect(profile.user.isEmpty ? null : profile.user,
              profile.pass.isEmpty ? null : profile.pass)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      c.disconnect();
      throw ApiException('Cannot reach cloud server ${profile.host}');
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      c.disconnect();
      throw ApiException('Cloud server refused the connection');
    }
    _brokerConnected = true;

    c.updates?.listen(_onMessages);
    c.subscribe('$base/status', MqttQos.atLeastOnce);
    c.subscribe('$base/online', MqttQos.atLeastOnce);
    c.subscribe('$base/reply', MqttQos.atLeastOnce);

    // retained status arrives right after subscribing (if the device was ever online)
    try {
      await Future.wait([_firstStatus.future, _firstOnline.future]).timeout(wait);
    } catch (_) {
      close();
      throw ApiException('Device not found in the cloud. Check the key, '
          'and that the device is in Router mode with internet.');
    }
    if (!_online) {
      close();
      throw ApiException('Device is offline (last seen in the cloud, but not connected now)');
    }
  }

  void _onMessages(dynamic msgs) {
    if (msgs is! List) return;
    for (final m in msgs) {
      if (m is! MqttReceivedMessage) continue;
      final p = m.payload;
      if (p is! MqttPublishMessage) continue;
      final topic = (m.topic as String?) ?? '';
      final text = utf8.decode(p.payload.message, allowMalformed: true);
      _handle(topic, text);
    }
  }

  void _handle(String topic, String text) {
    if (topic == '$base/online') {
      _online = text == 'online';
      if (!_firstOnline.isCompleted) _firstOnline.complete();
      _changes.add(null);
      return;
    }
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(text);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}

    if (topic == '$base/status') {
      _status = j;
      _statusAt = DateTime.now();
      if (j != null) parseLamps(j);
      if (!_firstStatus.isCompleted) _firstStatus.complete();
      _changes.add(null);
    } else if (topic == '$base/reply' && j != null) {
      final c = _pending.remove('${j['req']}');
      c?.complete(j);
    }
  }

  Future<Map<String, dynamic>> _request(String cmd, [Map<String, dynamic>? args,
      Duration timeout = const Duration(seconds: 10)]) async {
    final c = _client;
    if (c == null || !_brokerConnected) throw ApiException('Not connected to the cloud');
    if (!_online) throw ApiException('Device is offline');

    final req = _id();
    final completer = Completer<Map<String, dynamic>>();
    _pending[req] = completer;
    final body = jsonEncode({'req': req, 'cmd': cmd, ...?args});
    final b = MqttClientPayloadBuilder()..addUTF8String(body);
    c.publishMessage('$base/cmd', MqttQos.atLeastOnce, b.payload!);

    Map<String, dynamic> j;
    try {
      j = await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(req);
      throw ApiException('Device did not answer through the cloud');
    }
    if (j['ok'] == false) throw ApiException('${j['error'] ?? 'Command failed'}');
    return j;
  }

  // ---------------- DeviceApi ----------------

  @override
  Future<DeviceInfo> info({Duration? timeout}) async {
    final j = await _request('info', null, timeout ?? const Duration(seconds: 10));
    parseLamps(j);
    return DeviceInfo.fromJson(j, host);
  }

  /// Uses the last status the device published (no network traffic).
  @override
  Future<List<Lamp>> status() async {
    if (!_brokerConnected) throw ApiException('Cloud connection lost - reconnecting...');
    if (!_online) throw ApiException('Device is offline');
    final s = _status;
    if (s == null) throw ApiException('Waiting for device...');
    final lamps = parseLamps(s);
    final passed = DateTime.now().difference(_statusAt).inSeconds;
    for (final l in lamps) {
      if (l.timer > 0) {
        l.timer = max(0, l.timer - passed);
        if (l.timer == 0) l.on = false;
      }
    }
    return lamps;
  }

  @override
  Future<List<Lamp>> setLamp(int id, bool on) async =>
      parseLamps(await _request('lamp', {'id': id, 'state': on ? 'on' : 'off'}));

  @override
  Future<List<Lamp>> setTimer(int id, int minutes) async =>
      parseLamps(await _request('timer', {'id': id, 'minutes': minutes}));

  @override
  Future<List<Lamp>> setAll(bool on) async =>
      parseLamps(await _request('all', {'state': on ? 'on' : 'off'}));

  @override
  Future<List<Lamp>> rename(int id, String name) async =>
      parseLamps(await _request('name', {'id': id, 'name': name}));

  @override
  Future<String> exportJson() async => DeviceApi.pretty(DeviceApi.backupOnly(await _request('export')));

  @override
  Future<List<Lamp>> importJson(String json, {bool names = true, bool states = true}) async {
    final data = jsonDecode(json);
    return parseLamps(await _request('import', {'data': data, 'names': names, 'states': states}));
  }

  @override
  Future<WifiSettings> wifi() async => WifiSettings.fromJson(await _request('wifi_get'));

  @override
  Future<List<WifiNetwork>> scan() async {
    final j = await _request('scan', null, const Duration(seconds: 25));
    final list = j['networks'];
    if (list is! List) return [];
    return list.whereType<Map<String, dynamic>>().map(WifiNetwork.fromJson).toList();
  }

  @override
  Future<bool> saveWifi({required bool router, String? ssid, String? pass, String? apPass}) async {
    final j = await _request('wifi_set', {
      'mode': router ? 'router' : 'hotspot',
      if (router) 'ssid': ssid ?? '',
      if (router && pass != null) 'pass': pass,
      if (apPass != null) 'ap_pass': apPass,
    });
    return j['rollback'] == true;
  }

  @override
  Future<MqttSettings> mqtt() async => MqttSettings.fromJson(await _request('mqtt_get'));

  @override
  Future<MqttSettings> saveMqtt({
    bool? enabled,
    String? host,
    int? port,
    String? user,
    String? pass,
    bool newKey = false,
  }) async {
    return MqttSettings.fromJson(await _request('mqtt_set', {
      if (enabled != null) 'enabled': enabled,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (user != null) 'user': user,
      if (pass != null) 'pass': pass,
      if (newKey) 'new_key': true,
    }));
  }

  @override
  Future<void> reboot() => _request('reboot');

  @override
  Future<void> resetWifi() => _request('reset_wifi');

  @override
  void close() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(ApiException('Closed'));
    }
    _pending.clear();
    try {
      _client?.autoReconnect = false;
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    _brokerConnected = false;
  }
}
