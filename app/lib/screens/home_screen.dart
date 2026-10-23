import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/lamp_card.dart';
import '../widgets/timer_sheet.dart';
import 'connect_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api, required this.info});

  final DeviceApi api;
  final DeviceInfo info;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late DeviceInfo _info;
  List<Lamp> _lamps = [];
  bool _loading = true;
  String? _error;
  final Set<int> _busy = {};
  bool _allBusy = false;
  int _failCount = 0;
  Timer? _poll;
  Timer? _tick;
  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    _info = widget.info;
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _startTimers();
    // cloud: the device pushes changes -> refresh right away
    _changesSub = widget.api.changes.listen((_) => _refresh(silent: true));
  }

  @override
  void dispose() {
    _stopTimers();
    _changesSub?.cancel();
    widget.api.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _startTimers();
    } else if (state == AppLifecycleState.paused) {
      _stopTimers();
    }
  }

  void _startTimers() {
    _stopTimers();
    // sync with the device (other phones / browser may change lamps)
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh(silent: true));
    // local countdown for timers
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      var changed = false;
      for (final l in _lamps) {
        if (l.timer > 0) {
          l.timer--;
          if (l.timer == 0) l.on = false;
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    });
  }

  void _stopTimers() {
    _poll?.cancel();
    _tick?.cancel();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_busy.isNotEmpty || _allBusy) return; // don't overwrite a running action
    try {
      final lamps = await widget.api.status();
      if (!mounted) return;
      setState(() {
        _lamps = lamps;
        _loading = false;
        _error = null;
        _failCount = 0;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _failCount++;
      if (!silent || _failCount >= 3) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _apply(Future<List<Lamp>> Function() action, {int? id}) async {
    setState(() {
      if (id == null) {
        _allBusy = true;
      } else {
        _busy.add(id);
      }
    });
    try {
      final lamps = await action();
      if (!mounted) return;
      setState(() {
        _lamps = lamps;
        _error = null;
      });
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } finally {
      if (mounted) {
        setState(() {
          if (id == null) {
            _allBusy = false;
          } else {
            _busy.remove(id);
          }
        });
      }
    }
  }

  void _snack(String text, {bool error = false, SnackBarAction? action}) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: error ? Colors.red.shade700 : null,
      behavior: SnackBarBehavior.floating,
      action: action,
    ));
  }

  Future<void> _toggle(Lamp lamp) async {
    final turnOn = !lamp.on;
    await _apply(() => widget.api.setLamp(lamp.id, turnOn), id: lamp.id);
    if (turnOn && mounted) {
      _snack('${lamp.name} is ON',
          action: SnackBarAction(
            label: 'AUTO-OFF',
            onPressed: () {
              final current = _lamps.where((l) => l.id == lamp.id);
              if (current.isNotEmpty) _openTimer(current.first);
            },
          ));
    }
  }

  Future<void> _openTimer(Lamp lamp) async {
    final minutes = await showTimerSheet(context, lamp);
    if (minutes == null) return;
    await _apply(() => widget.api.setTimer(lamp.id, minutes), id: lamp.id);
    if (minutes > 0) {
      _snack('${lamp.name} turns OFF in $minutes min');
    } else {
      _snack('Timer cancelled');
    }
  }

  Future<void> _rename(Lamp lamp) async {
    final ctl = TextEditingController(text: lamp.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename lamp ${lamp.id}'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 24,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. Kitchen',
            helperText: 'Leave empty for default name',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    await _apply(() => widget.api.rename(lamp.id, name.trim()), id: lamp.id);
  }

  Future<void> _menu(Lamp lamp) async {
    final colors = AppTheme.lampGradient(lamp.id);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(lamp.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Lamp ${lamp.id}  •  ${lamp.on ? 'ON' : 'OFF'}'),
              leading: CircleAvatar(
                backgroundColor: colors[1],
                child: const Icon(Icons.lightbulb, color: Colors.white),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(lamp.on ? Icons.power_settings_new : Icons.lightbulb),
              title: Text(lamp.on ? 'Turn OFF' : 'Turn ON'),
              onTap: () => Navigator.pop(ctx, 'toggle'),
            ),
            ListTile(
              leading: const Icon(Icons.timer),
              title: const Text('Auto-OFF timer'),
              subtitle: lamp.timer > 0 ? Text('OFF in ${formatDuration(lamp.timer)}') : null,
              onTap: () => Navigator.pop(ctx, 'timer'),
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'toggle') _toggle(lamp);
    if (choice == 'timer') _openTimer(lamp);
    if (choice == 'rename') _rename(lamp);
  }

  Future<void> _openSettings() async {
    _stopTimers();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(api: widget.api, info: _info)),
    );
    if (!mounted) return;
    try {
      final i = await widget.api.info();
      if (mounted) setState(() => _info = i);
    } catch (_) {}
    _refresh();
    _startTimers();
  }

  void _findDevice() {
    _stopTimers();
    _changesSub?.cancel();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const ConnectScreen(autoConnect: true)),
    );
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final showOpenWarning = !widget.api.isCloud && _mode != 'router' && !_info.apSecured;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header()),
            if (showOpenWarning) SliverToBoxAdapter(child: _openWarning()),
            if (_error != null) SliverToBoxAdapter(child: _errorBanner()),
            if (_loading)
              const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.95,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final lamp = _lamps[i];
                      return LampCard(
                        lamp: lamp,
                        busy: _busy.contains(lamp.id) || _allBusy,
                        onTap: () => _toggle(lamp),
                        onTimer: () => _openTimer(lamp),
                        onLongPress: () => _menu(lamp),
                      );
                    },
                    childCount: _lamps.length,
                  ),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  Widget _header() {
    final onCount = _lamps.where((l) => l.on).length;
    final timers = _lamps.where((l) => l.timer > 0).length;
    return Container(
      decoration: const BoxDecoration(
        gradient: AppTheme.header,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 8, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.home_rounded, color: Colors.white, size: 30),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Smart Home',
                      style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _chip(widget.api.isCloud ? Icons.cloud : Icons.home,
                      widget.api.isCloud ? 'Cloud' : 'Local'),
                  _chip(_mode == 'router' ? Icons.router : Icons.wifi_tethering,
                      DeviceInfo.modeLabelOf(_mode)),
                  GestureDetector(
                    onLongPress: () {
                      Clipboard.setData(ClipboardData(text: _ip));
                      _snack('IP $_ip copied');
                    },
                    child: _chip(Icons.lan, 'IP $_ip'),
                  ),
                  if (_info.routerSsid.isNotEmpty && _mode == 'router')
                    _chip(Icons.wifi, _info.routerSsid),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _pill(Icons.lightbulb, '$onCount of ${_lamps.isEmpty ? 15 : _lamps.length} ON'),
                  const SizedBox(width: 10),
                  if (timers > 0) _pill(Icons.timer, '$timers timer${timers > 1 ? 's' : ''}'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _mode => widget.api.lastMode ?? _info.mode;
  String get _ip => widget.api.lastIp ?? (_info.ip.isNotEmpty ? _info.ip : _info.host);

  Widget _chip(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 16),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white70)),
        ],
      );

  Widget _pill(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(45),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _openWarning() => Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
        child: Material(
          color: const Color(0xFFFFF4D6),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _openSettings,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.lock_open, color: Color(0xFFB7791F)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Hotspot has no password. Anyone nearby can control your lamps. '
                      'Tap to set a password.',
                      style: TextStyle(color: Color(0xFF7A5200)),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: Color(0xFFB7791F)),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _errorBanner() => Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.withAlpha(30),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.red.withAlpha(90)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.wifi_off, color: Colors.red),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: _refresh, child: const Text('Retry')),
                  FilledButton.tonal(onPressed: _findDevice, child: const Text('Find device')),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _bottomBar() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: Row(
            children: [
              Expanded(
                child: _bigButton('ALL ON', Icons.lightbulb, AppTheme.allOn,
                    () => _apply(() => widget.api.setAll(true))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _bigButton('ALL OFF', Icons.power_settings_new, AppTheme.allOff,
                    () => _apply(() => widget.api.setAll(false))),
              ),
            ],
          ),
        ),
      );

  Widget _bigButton(String text, IconData icon, Gradient g, VoidCallback onTap) {
    final enabled = !_allBusy && !_loading;
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Container(
        decoration: BoxDecoration(
          gradient: g,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(text,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
