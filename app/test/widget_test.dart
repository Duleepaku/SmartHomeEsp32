import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/models.dart';

void main() {
  test('parses /api/status JSON', () {
    final lamps = Lamp.listFromJson({
      'ok': true,
      'lamps': [
        {'id': 1, 'name': 'Kitchen', 'on': true, 'timer': 95},
        {'id': 2, 'name': 'Lamp 2', 'on': false, 'timer': 0},
      ],
    });
    expect(lamps.length, 2);
    expect(lamps.first.name, 'Kitchen');
    expect(lamps.first.on, isTrue);
    expect(lamps.first.timer, 95);
    expect(lamps[1].on, isFalse);
  });

  test('formats timer countdown', () {
    expect(formatDuration(95), '01:35');
    expect(formatDuration(3725), '1:02:05');
    expect(formatDuration(0), '00:00');
  });

  test('parses /api/info JSON', () {
    final d = DeviceInfo.fromJson({
      'device': 'SmartHome-ESP32',
      'fw': '2.0.0',
      'mode': 'router',
      'ap_secured': false,
      'router_ssid': 'MyWiFi',
    }, '192.168.1.40');
    expect(d.isRouter, isTrue);
    expect(d.modeLabel, 'Router');
    expect(d.host, '192.168.1.40');
  });

  test('cloud profile round trip', () {
    final p = CloudProfile(key: 'a7f3k9q2m8xz');
    final back = CloudProfile.fromJsonString(p.toJsonString());
    expect(back, isNotNull);
    expect(back!.key, 'a7f3k9q2m8xz');
    expect(back.host, kDefaultBroker);
    expect(back.port, 1883);
    expect(CloudProfile.fromJsonString('{"key":"short"}'), isNull);
  });

  test('parses lamp schedule', () {
    final lamps = Lamp.listFromJson({
      'lamps': [
        {'id': 1, 'name': 'Gate', 'on': false, 'timer': 0, 'sch': true, 'sch_on': 1080, 'sch_off': 360},
        {'id': 2, 'name': 'Lamp 2', 'on': false},
      ],
    });
    expect(lamps[0].schEnabled, isTrue);
    expect(lamps[0].scheduleText, '18:00 - 06:00');
    expect(formatHM12(1080), '6:00 PM');
    expect(formatHM12(0), '12:00 AM');
    expect(lamps[1].schEnabled, isFalse);
    expect(lamps[1].schOn, 1080);
  });
}
