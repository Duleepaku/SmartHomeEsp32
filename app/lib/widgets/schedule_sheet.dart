import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// What the schedule sheet returns.
class ScheduleChoice {
  ScheduleChoice({required this.enabled, required this.onMin, required this.offMin});

  final bool enabled;
  final int onMin;
  final int offMin;
}

/// Bottom sheet: daily ON / OFF time for one lamp.
/// [routerMode] / [timeOk] are only used for the info line.
Future<ScheduleChoice?> showScheduleSheet(
  BuildContext context,
  Lamp lamp, {
  required bool routerMode,
  required bool timeOk,
  required String deviceTime,
}) {
  return showModalBottomSheet<ScheduleChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _ScheduleSheet(
      lamp: lamp,
      routerMode: routerMode,
      timeOk: timeOk,
      deviceTime: deviceTime,
    ),
  );
}

class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet({
    required this.lamp,
    required this.routerMode,
    required this.timeOk,
    required this.deviceTime,
  });

  final Lamp lamp;
  final bool routerMode;
  final bool timeOk;
  final String deviceTime;

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  late bool _enabled;
  late int _on;
  late int _off;

  @override
  void initState() {
    super.initState();
    // opening the sheet means "I want a schedule" -> switch starts ON
    // (a new schedule starts with 6:00 PM -> 6:00 AM)
    _enabled = true;
    _on = widget.lamp.schOn;
    _off = widget.lamp.schOff;
  }

  Future<void> _pick(bool isOn) async {
    final cur = isOn ? _on : _off;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
      helpText: isOn ? 'Lamp ON at' : 'Lamp OFF at',
    );
    if (t == null) return;
    setState(() {
      if (isOn) {
        _on = t.hour * 60 + t.minute;
      } else {
        _off = t.hour * 60 + t.minute;
      }
    });
  }

  String get _duration {
    var d = _off - _on;
    if (d <= 0) d += 1440;
    final h = d ~/ 60, m = d % 60;
    return m == 0 ? '$h h' : '$h h $m min';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.lampGradient(widget.lamp.id);
    final same = _on == _off;
    final hint = Theme.of(context).hintColor;

    Widget info;
    if (!widget.routerMode) {
      info = _note(Icons.warning_amber, Colors.orange,
          'Schedules work only in Router mode (the device needs internet for the time). '
          'You can save it now - it starts working when the device is in Router mode.');
    } else if (!widget.timeOk) {
      info = _note(Icons.schedule, Colors.orange,
          'Device clock is not synced yet (waiting for internet). The schedule starts when it is.');
    } else {
      info = _note(Icons.check_circle, Colors.green,
          'Device time: ${widget.deviceTime}. Runs every day, even when the phone is off.');
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, color: colors[1]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Daily schedule: ${widget.lamp.name}',
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            info,
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              title: const Text('Schedule ON'),
              subtitle: const Text('Every day'),
            ),
            Opacity(
              opacity: _enabled ? 1 : 0.45,
              child: Row(
                children: [
                  Expanded(child: _timeBox('ON', _on, Icons.lightbulb, colors, () => _pick(true))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _timeBox('OFF', _off, Icons.power_settings_new,
                        const [Color(0xFF9AA0AE), Color(0xFF5B6170)], () => _pick(false)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              same
                  ? 'ON and OFF time must be different.'
                  : 'Lamp stays ON for $_duration'
                      '${_off <= _on ? ' (until the next morning)' : ''}.',
              textAlign: TextAlign.center,
              style: TextStyle(color: same ? Colors.red : hint),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: colors[1],
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: (_enabled && same)
                  ? null
                  : () => Navigator.pop(
                        context,
                        ScheduleChoice(enabled: _enabled, onMin: _on, offMin: _off),
                      ),
              icon: const Icon(Icons.save),
              label: Text(_enabled ? 'Save schedule' : 'Save (schedule OFF)'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _note(IconData icon, Color color, String text) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );

  Widget _timeBox(String label, int minutes, IconData icon, List<Color> colors, VoidCallback onTap) {
    return Material(
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: InkWell(
          onTap: _enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    Text(label,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  formatHM12(minutes),
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const Text('tap to change', style: TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
