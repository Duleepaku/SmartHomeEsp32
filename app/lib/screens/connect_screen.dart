import 'package:flutter/material.dart';

import '../api.dart';
import '../cloud_api.dart';
import '../discovery.dart';
import '../models.dart';
import '../storage.dart';
import '../theme.dart';
import 'home_screen.dart';

/// First screen. Order:
///  1. last used IP          (local, fast)
///  2. hotspot 192.168.4.1   (local)
///  3. cloud (MQTT)          if the phone was paired before
///  4. UDP broadcast + network scan (local)
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.autoConnect = true});

  /// true = open the device automatically when it is found.
  final bool autoConnect;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  String _status = 'Starting...';
  double? _progress;
  bool _searching = false;
  bool _cancelled = false;
  bool _opened = false;
  List<DeviceInfo> _found = [];
  CloudProfile? _cloud;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  void _set(String status, [double? progress]) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _progress = progress;
    });
  }

  Future<void> _search() async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _found = [];
    });
    _cloud = await Storage.cloud();
    final auto = widget.autoConnect;

    // 1. last used device
    final last = await Storage.lastIp();
    if (last != null && last != Discovery.hotspotIp) {
      _set('Trying $last ...');
      final d = await Discovery.probe(last, timeout: const Duration(milliseconds: 1500));
      if (d != null) {
        if (auto) return _openLocal(d);
        _found = [d];
      }
    }
    if (_cancelled) return;

    // 2. hotspot
    _set('Checking hotspot ${Discovery.hotspotIp} ...');
    final hs = await Discovery.probe(Discovery.hotspotIp, timeout: const Duration(milliseconds: 1500));
    if (hs != null) {
      if (auto) return _openLocal(hs);
      if (!_found.any((d) => d.host == hs.host)) _found.add(hs);
    }
    if (_cancelled) return;

    // 3. cloud
    if (auto && _cloud != null && _found.isEmpty) {
      _set('Connecting through the cloud ...');
      final ok = await _tryCloud(_cloud!, showError: false);
      if (ok || _cancelled) return;
    }

    // 4. local network scan
    final list = await Discovery.discover(
      onStatus: _set,
      cancelled: () => _cancelled,
      skipHotspot: true,
    );
    if (!mounted || _opened) return;
    for (final d in list) {
      if (!_found.any((f) => f.host == d.host)) _found.add(d);
    }
    setState(() {
      _searching = false;
      _progress = null;
      _status = _found.isEmpty
          ? 'No device found on this WiFi'
          : '${_found.length} device${_found.length > 1 ? 's' : ''} found';
    });
    if (auto && _found.length == 1) _openLocal(_found.first);
  }

  Future<void> _openLocal(DeviceInfo d) async {
    if (_opened) return;
    _opened = true;
    _cancelled = true;
    await Storage.setLastIp(d.host);
    await Storage.pairFromInfo(d); // remember the cloud key
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => HomeScreen(api: HttpDeviceApi(d.host), info: d)),
    );
  }

  /// Returns true when the home screen was opened.
  Future<bool> _tryCloud(CloudProfile p, {bool showError = true}) async {
    final api = MqttDeviceApi(p);
    try {
      await api.connect();
      final info = await api.info();
      if (!mounted || _opened) {
        api.close();
        return false;
      }
      _opened = true;
      _cancelled = true;
      await Storage.setCloud(p);
      if (!mounted) return true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen(api: api, info: info)),
      );
      return true;
    } on ApiException catch (e) {
      api.close();
      if (showError) {
        _set(e.message);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
      return false;
    }
  }

  Future<void> _manual() async {
    final ctl = TextEditingController(text: Discovery.hotspotIp);
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter device IP'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.50'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Connect')),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    _set('Connecting to $ip ...');
    final d = await Discovery.probe(ip, timeout: const Duration(seconds: 3));
    if (d != null) {
      _opened = false;
      _openLocal(d);
    } else {
      _set('No Smart Home device at $ip');
    }
  }

  Future<void> _cloudDialog() async {
    final p = await showDialog<CloudProfile>(
      context: context,
      builder: (ctx) => _CloudDialog(initial: _cloud),
    );
    if (p == null) return;
    setState(() => _searching = true);
    _set('Connecting through the cloud ...');
    _opened = false;
    final ok = await _tryCloud(p);
    if (!ok && mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.header),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(26),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(40),
                    boxShadow: [BoxShadow(color: Colors.white.withAlpha(60), blurRadius: 30)],
                  ),
                  child: const Icon(Icons.home_rounded, size: 72, color: Colors.white),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Smart Home',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                '15 Lamp Controller',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 32),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              if (_searching)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 6,
                    color: Colors.white,
                    backgroundColor: Colors.white.withAlpha(50),
                  ),
                ),
              const SizedBox(height: 16),
              for (final d in _found) _deviceTile(d),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppTheme.seed,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _searching
                          ? null
                          : () {
                              _cancelled = false;
                              _opened = false;
                              _search();
                            },
                      icon: const Icon(Icons.search),
                      label: const Text('Search again'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: _outline,
                      onPressed: _manual,
                      icon: const Icon(Icons.edit),
                      label: const Text('Enter IP'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: _outline,
                onPressed: _searching ? null : _cloudDialog,
                icon: const Icon(Icons.cloud),
                label: Text(_cloud == null ? 'Connect through cloud (enter key)' : 'Connect through cloud'),
              ),
              const SizedBox(height: 28),
              _help(),
            ],
          ),
        ),
      ),
    );
  }

  ButtonStyle get _outline => OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white70),
        padding: const EdgeInsets.symmetric(vertical: 14),
      );

  Widget _deviceTile(DeviceInfo d) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: CircleAvatar(
            backgroundColor: AppTheme.seed,
            child: Icon(d.isRouter ? Icons.router : Icons.wifi_tethering, color: Colors.white),
          ),
          title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${d.host}  •  ${d.modeLabel}  •  v${d.fw}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            _opened = false;
            _openLocal(d);
          },
        ),
      );

  Widget _help() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(35),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How to connect',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
            SizedBox(height: 8),
            Text(
              '• First time: connect your phone WiFi to "Smart Home", then tap Search again.\n'
              '• Router mode: phone on the same WiFi → found automatically.\n'
              '• Away from home: connect once at home (the app saves the cloud key), '
              'then the app uses the cloud automatically.\n'
              '• If the phone asks "WiFi has no internet - stay connected?", choose Yes.\n'
              '• Forgot passwords? Hold the reset button (ESP32: GPIO14, ESP8266: RX) while powering on for 5 seconds.',
              style: TextStyle(color: Colors.white, height: 1.5),
            ),
          ],
        ),
      );
}

/// Dialog to type / edit the cloud key and broker.
class _CloudDialog extends StatefulWidget {
  const _CloudDialog({this.initial});
  final CloudProfile? initial;

  @override
  State<_CloudDialog> createState() => _CloudDialogState();
}

class _CloudDialogState extends State<_CloudDialog> {
  late final TextEditingController _key;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  bool _advanced = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    _key = TextEditingController(text: p?.key ?? '');
    _host = TextEditingController(text: p?.host ?? kDefaultBroker);
    _port = TextEditingController(text: '${p?.port ?? kDefaultBrokerPort}');
    _user = TextEditingController(text: p?.user ?? '');
    _pass = TextEditingController(text: p?.pass ?? '');
  }

  @override
  void dispose() {
    for (final c in [_key, _host, _port, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  void _ok() {
    final key = _key.text.trim().toLowerCase();
    final port = int.tryParse(_port.text.trim());
    if (key.length < 8) return setState(() => _error = 'Key is too short');
    if (port == null || port < 1 || port > 65535) return setState(() => _error = 'Port is not valid');
    Navigator.pop(
      context,
      CloudProfile(
        key: key,
        host: _host.text.trim().isEmpty ? kDefaultBroker : _host.text.trim(),
        port: port,
        user: _user.text.trim(),
        pass: _pass.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.cloud, size: 40),
      title: const Text('Cloud connection'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the secret key of your device. You can see it in the app '
              'Settings, on the device web page (/setup) or in the Serial Monitor.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              decoration: InputDecoration(
                labelText: 'Secret key',
                prefixIcon: const Icon(Icons.key),
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => setState(() => _advanced = !_advanced),
              child: Text(_advanced ? 'Hide broker settings' : 'Broker settings'),
            ),
            if (_advanced) ...[
              TextField(
                controller: _host,
                decoration: const InputDecoration(labelText: 'Broker', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'Username (optional)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password (optional)', border: OutlineInputBorder()),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _ok, child: const Text('Connect')),
      ],
    );
  }
}
