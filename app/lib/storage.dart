import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Remembers the last device (local IP + cloud key) on the phone.
class Storage {
  static const _lastIpKey = 'last_ip';
  static const _cloudKey = 'cloud_profile';

  static Future<String?> lastIp() async =>
      (await SharedPreferences.getInstance()).getString(_lastIpKey);

  static Future<void> setLastIp(String ip) async =>
      (await SharedPreferences.getInstance()).setString(_lastIpKey, ip);

  static Future<CloudProfile?> cloud() async =>
      CloudProfile.fromJsonString((await SharedPreferences.getInstance()).getString(_cloudKey));

  static Future<void> setCloud(CloudProfile p) async =>
      (await SharedPreferences.getInstance()).setString(_cloudKey, p.toJsonString());

  static Future<void> clearCloud() async =>
      (await SharedPreferences.getInstance()).remove(_cloudKey);

  /// Called after a LOCAL connection: saves the device's cloud key
  /// ("pairing") so the app can reach it later from any network.
  static Future<void> pairFromInfo(DeviceInfo d) async {
    if (d.key.length < 8) return;
    final old = await cloud();
    var user = '';
    var pass = '';
    if (old != null && old.host == d.mqttHost && old.port == d.mqttPort) {
      user = old.user;
      pass = old.pass;
    }
    await setCloud(CloudProfile(
      key: d.key,
      host: d.mqttHost,
      port: d.mqttPort,
      user: user,
      pass: pass,
    ));
  }
}
