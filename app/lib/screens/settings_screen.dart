import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../storage.dart';
import 'connect_screen.dart';

const String kAppVersion = '2.0.0';
const String kRepoUrl = 'github.com/YOUR_GITHUB_USERNAME/smart-home-esp32';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api, required this.info});

  final DeviceApi api;
  final DeviceInfo info;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late DeviceInfo _info;
  WifiSettings? _wifi;
  bool _router = false;
  bool _openHotspot = false;
  bool _saving = false;
  bool _hideApPass = true;
  bool _hidePass = true;

  final _ssidCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _apPassCtl = TextEditingController();

  MqttSettings? _mq;
  bool _mqEnabled = true;
  final _mqHost = TextEditingController(text: kDefaultBroker);
  final _mqPort = TextEditingController(text: '$kDefaultBrokerPort');
  final _mqUser = TextEditingController();
  final _mqPass = TextEditingController();

  @override
  void initState() {
    super.initState();
    _info = widget.info;
    _router = _info.mode != 'hotspot';
    _load();
  }

  @override
  void dispose() {
    _ssidCtl.dispose();
    _passCtl.dispose();
    _apPassCtl.dispose();
    _mqHost.dispose();
    _mqPort.dispose();
    _mqUser.dispose();
    _mqPass.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await widget.api.info();
      final wifi = await widget.api.wifi();
      final mq = await widget.api.mqtt();
      if (!mounted) return;
      setState(() {
        _info = info;
        _wifi = wifi;
        _router = wifi.router;
        _ssidCtl.text = wifi.routerSsid;
        _mq = mq;
        _mqEnabled = mq.enabled;
        _mqHost.text = mq.host;
        _mqPort.text = '${mq.port}';
        _mqUser.text = mq.user;
      });
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    }
  }

  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? Colors.red.shade700 : null,
      ));
  }

  Future<bool> _confirm(String title, String text, {String ok = 'OK'}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    );
    return r == true;
  }

  void _goToConnect({bool auto = true}) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => ConnectScreen(autoConnect: auto)),
      (_) => false,
    );
  }

  // ---------------------------------------------------------------- WiFi

  Future<void> _scan() async {
    final ssid = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ScanSheet(api: widget.api),
    );
    if (ssid != null) setState(() => _ssidCtl.text = ssid);
  }

  Future<void> _saveWifi() async {
    final apPass = _apPassCtl.text;
    final ssid = _ssidCtl.text.trim();

    if (!_openHotspot && apPass.isNotEmpty && (apPass.length < 8 || apPass.length > 63)) {
      _snack('Hotspot password must be 8-63 characters', error: true);
      return;
    }
    if (_router && ssid.isEmpty) {
      _snack('Enter the router WiFi name (SSID)', error: true);
      return;
    }

    final cloud = widget.api.isCloud;
    final String text;
    if (_router) {
      text = cloud
          ? 'The device will restart and join "$ssid".\n\n'
              'It comes back online in the cloud in about 30 seconds (if "$ssid" has internet).\n\n'
              'If it cannot join "$ssid", it goes back to the current router automatically.'
          : 'The device will restart and join "$ssid".\n\n'
              'The app then finds it again automatically (same WiFi, or through the cloud) '
              'and shows its new IP address.\n\n'
              'If the router password is wrong, the device starts the backup hotspot '
              '"Smart Home" after about 20 seconds.';
    } else {
      final changed = _openHotspot || apPass.isNotEmpty;
      text = cloud
          ? 'WARNING: in Hotspot mode the device has NO internet, so cloud control STOPS.\n\n'
              'You will need to be near the device and connect to the "Smart Home" WiFi.'
          : 'The device will restart as hotspot "Smart Home" (192.168.4.1).'
              '${changed ? '\n\nReconnect your phone to "Smart Home"${_openHotspot ? ' (no password)' : ' with the NEW password'}, then tap "Search again".' : ''}';
    }
    if (!await _confirm('Save WiFi settings?', text, ok: 'Save & restart')) return;

    // empty router password + same SSID = keep the saved password
    String? pass = _passCtl.text;
    if (pass.isEmpty && ssid == _wifi?.routerSsid) pass = null;

    setState(() => _saving = true);
    try {
      final rollback = await widget.api.saveWifi(
        router: _router,
        ssid: ssid,
        pass: pass,
        apPass: _openHotspot ? '' : (apPass.isEmpty ? null : apPass),
      );
      if (!mounted) return;
      final String done;
      if (cloud) {
        done = _router
            ? 'Device is restarting. Wait about 30 seconds - the lamps screen updates by itself.'
                '${rollback ? '\n\nIf "$ssid" does not work, the old router is used again.' : ''}'
            : 'Device is restarting in Hotspot mode. Cloud control is now off.';
      } else {
        done = _router
            ? 'Device is restarting.\n\nConnect your phone to "$ssid" (or use mobile data - the cloud '
                'works too), then the app finds the device and shows its new IP.'
            : 'Device is restarting.\n\nConnect your phone to "Smart Home", then tap "Search again".';
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
          title: const Text('Saved'),
          content: Text(done),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      if (!mounted) return;
      if (cloud) {
        Navigator.pop(context);
      } else {
        _goToConnect(auto: true);
      }
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------- Cloud

  Future<void> _saveCloud({bool newKey = false}) async {
    final host = _mqHost.text.trim();
    final port = int.tryParse(_mqPort.text.trim());
    if (host.length < 3) {
      _snack('Enter the broker address', error: true);
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      _snack('Port is not valid', error: true);
      return;
    }

    final old = _mq;
    final changesLink = newKey || !_mqEnabled || host != old?.host || port != old?.port ||
        _mqUser.text.trim() != (old?.user ?? '');
    if (newKey &&
        !await _confirm('Make a new secret key?',
            'All phones (also this one, if it is not on the same WiFi) must connect again '
            'with the new key. Use this if someone else got your key.',
            ok: 'New key')) {
      return;
    }
    if (widget.api.isCloud && changesLink && !newKey &&
        !await _confirm('Change cloud settings?',
            'You are connected through the cloud. The app will reconnect with the new settings.')) {
      return;
    }

    setState(() => _saving = true);
    try {
      final passText = _mqPass.text;
      final mq = await widget.api.saveMqtt(
        enabled: _mqEnabled,
        host: host,
        port: port,
        user: _mqUser.text.trim(),
        pass: passText.isEmpty ? null : passText,
        newKey: newKey,
      );
      final saved = await Storage.cloud();
      await Storage.setCloud(CloudProfile(
        key: mq.key,
        host: mq.host,
        port: mq.port,
        user: mq.user,
        pass: passText.isNotEmpty ? passText : (saved?.pass ?? ''),
      ));
      if (!mounted) return;
      setState(() => _mq = mq);
      _snack(newKey ? 'New key: ${mq.key}' : 'Cloud settings saved');
      if (widget.api.isCloud && changesLink) _goToConnect(auto: true);
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------- Backup

  String _fileName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'smarthome-backup-${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}.json';
  }

  Future<void> _exportFile() async {
    try {
      final json = await widget.api.exportJson();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save backup',
        fileName: _fileName(),
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      _snack(path == null ? 'Cancelled' : 'Backup saved');
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } catch (e) {
      _snack('Could not save file ($e). Use "Copy JSON" instead.', error: true);
    }
  }

  Future<void> _exportClipboard() async {
    try {
      final json = await widget.api.exportJson();
      await Clipboard.setData(ClipboardData(text: json));
      _snack('Backup JSON copied to clipboard');
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    }
  }

  Future<void> _importFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      if (res == null || res.files.isEmpty) return;
      final bytes = res.files.first.bytes;
      if (bytes == null) {
        _snack('Could not read the file', error: true);
        return;
      }
      await _import(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      _snack('Could not open file: $e', error: true);
    }
  }

  Future<void> _importPaste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final ctl = TextEditingController(text: clip?.text ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste backup JSON'),
        content: TextField(
          controller: ctl,
          maxLines: 10,
          minLines: 5,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Next')),
        ],
      ),
    );
    if (text != null) await _import(text);
  }

  Future<void> _import(String text) async {
    // check the JSON in the app first
    int count;
    try {
      final j = jsonDecode(text);
      final lamps = j is Map<String, dynamic> ? j['lamps'] : null;
      if (lamps is! List || lamps.isEmpty) throw const FormatException();
      count = lamps.length;
    } catch (_) {
      _snack('This is not a Smart Home backup JSON', error: true);
      return;
    }
    if (!mounted) return;

    var names = true;
    var states = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Restore backup'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$count lamps in this backup. What do you want to restore?'),
              CheckboxListTile(
                value: names,
                onChanged: (v) => setD(() => names = v ?? true),
                title: const Text('Lamp names'),
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                value: states,
                onChanged: (v) => setD(() => states = v ?? true),
                title: const Text('ON / OFF states'),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: (names || states) ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Restore'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.importJson(text, names: names, states: states);
      _snack('Backup restored');
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    }
  }

  // ---------------------------------------------------------------- Maintenance

  Future<void> _reboot() async {
    if (!await _confirm('Restart device?', 'Lamps keep their state. Timers are cancelled.')) return;
    try {
      await widget.api.reboot();
      _snack('Restarting... wait 10 seconds');
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    }
  }

  Future<void> _resetWifi() async {
    if (!await _confirm(
        'Reset WiFi settings?',
        'Router name/password and hotspot password are erased. '
            'The device restarts as an OPEN hotspot "Smart Home".\n\n'
            'Lamp names, states and the cloud key are kept.'
            '${widget.api.isCloud ? '\n\nWARNING: cloud control STOPS (hotspot has no internet).' : ''}',
        ok: 'Reset')) {
      return;
    }
    try {
      await widget.api.resetWifi();
      if (mounted) _goToConnect(auto: true);
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        foregroundColor: Colors.white,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF6C4DF5), Color(0xFFE0457B)]),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _section('Device', Icons.memory, const Color(0xFF42A5F5), _deviceInfo()),
            _section('WiFi mode', Icons.wifi, const Color(0xFF6C4DF5), _wifiForm()),
            _section('Cloud (MQTT)', Icons.cloud, const Color(0xFF26C6DA), _cloudForm()),
            _section('Backup (JSON)', Icons.data_object, const Color(0xFF26A69A), _backup()),
            _section('Maintenance', Icons.build, const Color(0xFFFF8A3D), _maintenance()),
            _section('About', Icons.info_outline, const Color(0xFFF06292), _about()),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, IconData icon, Color color, Widget child) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 120, child: Text(k, style: TextStyle(color: Theme.of(context).hintColor))),
            Expanded(child: Text(v.isEmpty ? '-' : v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  Widget _deviceInfo() => Column(
        children: [
          _row('Mode', _info.modeLabel),
          _row('Device IP', _info.ip),
          _row('Connected via', widget.api.isCloud ? 'Cloud (MQTT)' : 'Local WiFi (${_info.host})'),
          _row('Hotspot', '${_info.apSsid}  (${_info.apSecured ? 'password' : 'OPEN'})'),
          if (_info.routerSsid.isNotEmpty) _row('Router', _info.routerSsid),
          if (_info.routerIp.isNotEmpty) _row('Router IP', _info.routerIp),
          if (_info.isRouter) _row('Signal', '${_info.rssi} dBm'),
          _row('Firmware', 'v${_info.fw}'),
          _row('MAC', _info.mac),
          _row('Uptime', formatUptime(_info.uptime)),
        ],
      );

  Widget _cloudForm() {
    final mq = _mq;
    final connected = mq?.connected ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Control your lamps from any network (mobile data, office WiFi...). '
          'Works when the device is in Router mode with internet.',
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(connected ? Icons.cloud_done : Icons.cloud_off,
                color: connected ? Colors.green : Colors.grey),
            const SizedBox(width: 8),
            Text(
              mq == null
                  ? 'Loading...'
                  : !mq.enabled
                      ? 'Cloud is OFF'
                      : connected
                          ? 'Device is connected to the cloud'
                          : (_info.isRouter ? 'Device is connecting...' : 'Needs Router mode'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Text('Secret key', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF26C6DA).withAlpha(30),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  mq?.key ?? _info.key,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 20, letterSpacing: 2),
                ),
              ),
              IconButton(
                tooltip: 'Copy key',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: mq?.key ?? _info.key));
                  _snack('Key copied - paste it in the app on another phone');
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Keep this key private: anyone with it can control your lamps.',
          style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _mqEnabled,
          onChanged: (v) => setState(() => _mqEnabled = v),
          title: const Text('Cloud enabled'),
        ),
        TextField(
          controller: _mqHost,
          decoration: const InputDecoration(
            labelText: 'Broker',
            prefixIcon: Icon(Icons.dns),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _mqPort,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Port',
            prefixIcon: Icon(Icons.numbers),
            border: OutlineInputBorder(),
          ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Username / password (private broker only)'),
          children: [
            TextField(
              controller: _mqUser,
              decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _mqPass,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                helperText: 'Empty = keep the saved password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : () => _saveCloud(newKey: true),
                icon: const Icon(Icons.autorenew),
                label: const Text('New key'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _saving ? null : () => _saveCloud(),
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _wifiForm() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.wifi_tethering), label: Text('Hotspot')),
              ButtonSegment(value: true, icon: Icon(Icons.router), label: Text('Router')),
            ],
            selected: {_router},
            onSelectionChanged: (s) => setState(() => _router = s.first),
          ),
          const SizedBox(height: 10),
          Text(
            _router
                ? 'The device joins your home WiFi router. Phone and device must be on the same router.'
                : 'The device makes its own WiFi "Smart Home". Phone connects directly to 192.168.4.1.',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
          if (_router) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _ssidCtl,
              decoration: InputDecoration(
                labelText: 'Router WiFi name (SSID)',
                prefixIcon: const Icon(Icons.router),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Scan',
                  icon: const Icon(Icons.wifi_find),
                  onPressed: _scan,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtl,
              obscureText: _hidePass,
              decoration: InputDecoration(
                labelText: 'Router password',
                helperText: (_wifi?.routerSsid.isNotEmpty ?? false)
                    ? 'Leave empty to keep the saved password'
                    : null,
                prefixIcon: const Icon(Icons.key),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_hidePass ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _hidePass = !_hidePass),
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            _router ? 'Hotspot password (used for the backup hotspot)' : 'Hotspot password',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _apPassCtl,
            enabled: !_openHotspot,
            obscureText: _hideApPass,
            decoration: InputDecoration(
              labelText: _info.apSecured ? 'New password (empty = no change)' : 'Set a password (8-63 chars)',
              prefixIcon: const Icon(Icons.lock),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_hideApPass ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hideApPass = !_hideApPass),
              ),
            ),
          ),
          if (_info.apSecured)
            CheckboxListTile(
              value: _openHotspot,
              onChanged: (v) => setState(() => _openHotspot = v ?? false),
              title: const Text('Remove password (open hotspot)'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _saveWifi,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: const Text('Save & restart device'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          ),
        ],
      );

  Widget _action(IconData icon, String title, String sub, VoidCallback onTap, {Color? color}) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color),
        title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        subtitle: Text(sub),
        onTap: onTap,
      );

  Widget _backup() => Column(
        children: [
          _action(Icons.download, 'Download backup file', 'Save lamp names & states as .json', _exportFile),
          _action(Icons.copy, 'Copy JSON', 'Copy the backup to the clipboard', _exportClipboard),
          _action(Icons.upload_file, 'Upload backup file', 'Restore from a .json file', _importFile),
          _action(Icons.content_paste, 'Paste JSON', 'Restore from copied text', _importPaste),
        ],
      );

  Widget _maintenance() => Column(
        children: [
          _action(Icons.devices, 'Change device', 'Search for another Smart Home device',
              () => _goToConnect(auto: false)),
          _action(Icons.restart_alt, 'Restart device', 'Reboot the ESP32', _reboot),
          _action(Icons.wifi_off, 'Reset WiFi settings', 'Back to open "Smart Home" hotspot', _resetWifi,
              color: Colors.red),
        ],
      );

  Widget _about() => Column(
        children: [
          _row('App', 'Smart Home v$kAppVersion'),
          _row('Firmware', 'v${_info.fw}'),
          _row('Source', kRepoUrl),
          _row('Reset button', 'GPIO14 - hold 5 s at power on'),
        ],
      );
}

/// Bottom sheet that asks the ESP32 to scan nearby WiFi networks.
class _ScanSheet extends StatefulWidget {
  const _ScanSheet({required this.api});
  final DeviceApi api;

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  late Future<List<WifiNetwork>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.scan();
  }

  IconData _signal(int rssi) {
    if (rssi > -55) return Icons.signal_wifi_4_bar;
    if (rssi > -67) return Icons.network_wifi_3_bar;
    if (rssi > -78) return Icons.network_wifi_2_bar;
    return Icons.network_wifi_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Nearby WiFi networks', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: FutureBuilder<List<WifiNetwork>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('Scanning... (about 5 seconds)'),
                        ],
                      ),
                    );
                  }
                  if (snap.hasError) {
                    return Center(child: Text('Scan failed: ${snap.error}'));
                  }
                  final list = snap.data ?? [];
                  if (list.isEmpty) return const Center(child: Text('No networks found'));
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final n = list[i];
                      return ListTile(
                        leading: Icon(_signal(n.rssi)),
                        title: Text(n.ssid),
                        subtitle: Text('${n.rssi} dBm'),
                        trailing: Icon(n.secure ? Icons.lock : Icons.lock_open, size: 18),
                        onTap: () => Navigator.pop(context, n.ssid),
                      );
                    },
                  );
                },
              ),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _future = widget.api.scan()),
              icon: const Icon(Icons.refresh),
              label: const Text('Scan again'),
            ),
          ],
        ),
      ),
    );
  }
}
