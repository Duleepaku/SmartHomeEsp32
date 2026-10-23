import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';

/// Finds the ESP32 on the network:
///  1. hotspot address 192.168.4.1
///  2. UDP broadcast "SMARTHOME_DISCOVER" on port 4210
///  3. HTTP scan of the phone's WiFi subnet (x.x.x.1 - x.x.x.254)
class Discovery {
  static const String hotspotIp = '192.168.4.1';
  static const int udpPort = 4210;
  static const String deviceId = 'SmartHome-ESP32';

  /// Checks one IP. Returns device info if a Smart Home board answers.
  static Future<DeviceInfo?> probe(String ip,
      {Duration timeout = const Duration(milliseconds: 900)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .getUrl(Uri(scheme: 'http', host: ip, path: '/api/info'))
          .timeout(timeout);
      final res = await req.close().timeout(timeout * 2);
      final body = await res.transform(utf8.decoder).join().timeout(timeout * 2);
      final j = jsonDecode(body);
      if (j is Map<String, dynamic> && j['device'] == deviceId) {
        return DeviceInfo.fromJson(j, ip);
      }
    } catch (_) {
      // not a Smart Home device / not reachable
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Private IPv4 addresses of the phone (WiFi first, mobile data skipped).
  static Future<List<String>> localIPv4() async {
    final out = <String>[];
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      ifs.sort((a, b) =>
          (b.name.startsWith('wlan') ? 1 : 0) - (a.name.startsWith('wlan') ? 1 : 0));
      for (final i in ifs) {
        final n = i.name;
        if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('tun')) {
          continue;
        }
        for (final a in i.addresses) {
          if (_isPrivate(a.address) && !out.contains(a.address)) out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  static bool _isPrivate(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.contains(null)) return false;
    final a = p[0]!, b = p[1]!;
    return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  static String _subnet(String ip) => ip.substring(0, ip.lastIndexOf('.'));

  static Future<List<DeviceInfo>> udpDiscover(List<String> myIps,
      {Duration wait = const Duration(milliseconds: 1500)}) async {
    final found = <String, DeviceInfo>{};
    RawDatagramSocket? sock;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock = s;
      s.broadcastEnabled = true;
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        try {
          final j = jsonDecode(utf8.decode(d.data));
          if (j is Map<String, dynamic> && j['device'] == deviceId) {
            final ip = d.address.address;
            found[ip] = DeviceInfo.fromJson(j, ip);
          }
        } catch (_) {}
      });

      final msg = utf8.encode('SMARTHOME_DISCOVER');
      final targets = <String>{
        '255.255.255.255',
        for (final ip in myIps) '${_subnet(ip)}.255',
      };
      for (var k = 0; k < 3; k++) {
        for (final t in targets) {
          try {
            s.send(msg, InternetAddress(t), udpPort);
          } catch (_) {}
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await Future<void>.delayed(wait);
    } catch (_) {
      // broadcast not allowed on this network - HTTP scan will be used
    } finally {
      sock?.close();
    }
    return found.values.toList();
  }

  static Future<List<DeviceInfo>> sweep(List<String> myIps,
      {void Function(double progress)? onProgress, bool Function()? cancelled}) async {
    final subnets = myIps.map(_subnet).toSet().take(2);
    final hosts = <String>[
      for (final s in subnets)
        for (var h = 1; h < 255; h++) '$s.$h',
    ]..removeWhere(myIps.contains);

    final found = <DeviceInfo>[];
    const batch = 32;
    for (var i = 0; i < hosts.length; i += batch) {
      if (cancelled?.call() ?? false) break;
      final part = hosts.sublist(i, min(i + batch, hosts.length));
      final res = await Future.wait(
          part.map((h) => probe(h, timeout: const Duration(milliseconds: 700))));
      found.addAll(res.whereType<DeviceInfo>());
      onProgress?.call(min(1.0, (i + batch) / hosts.length));
    }
    return found;
  }

  /// Full search. [onStatus] gets a text and an optional progress 0..1.
  static Future<List<DeviceInfo>> discover({
    void Function(String status, double? progress)? onStatus,
    bool Function()? cancelled,
    bool skipHotspot = false,
  }) async {
    final found = <String, DeviceInfo>{};

    if (!skipHotspot) {
      onStatus?.call('Checking hotspot $hotspotIp ...', null);
      final hs = await probe(hotspotIp, timeout: const Duration(milliseconds: 1500));
      if (hs != null) return [hs];
    }
    if (cancelled?.call() ?? false) return [];

    final ips = await localIPv4();
    if (ips.isEmpty) return [];

    onStatus?.call('Searching the network ...', null);
    for (final d in await udpDiscover(ips)) {
      found[d.host] = d;
    }
    if (found.isNotEmpty || (cancelled?.call() ?? false)) return found.values.toList();

    onStatus?.call('Scanning ${_subnet(ips.first)}.x ...', 0);
    final swept = await sweep(ips,
        onProgress: (p) => onStatus?.call('Scanning ${_subnet(ips.first)}.x ...', p),
        cancelled: cancelled);
    for (final d in swept) {
      found[d.host] = d;
    }
    return found.values.toList();
  }
}
