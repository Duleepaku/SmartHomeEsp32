import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// Bottom sheet to choose "turn OFF after X minutes".
/// Returns minutes, 0 = cancel timer, null = closed.
Future<int?> showTimerSheet(BuildContext context, Lamp lamp) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _TimerSheet(lamp: lamp),
  );
}

class _TimerSheet extends StatelessWidget {
  const _TimerSheet({required this.lamp});

  final Lamp lamp;

  static const presets = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240];

  String _label(int m) => m < 60 ? '$m min' : (m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${m % 60} m');

  Future<void> _custom(BuildContext context) async {
    final ctl = TextEditingController();
    final m = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom timer'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Minutes (1 - 1440)',
            suffixText: 'min',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctl.text.trim());
              if (v != null && v >= 1 && v <= 1440) Navigator.pop(ctx, v);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (m != null && context.mounted) Navigator.pop(context, m);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.lampGradient(lamp.id);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timer, color: colors[1]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Auto-OFF: ${lamp.name}',
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              lamp.timer > 0
                  ? 'Turns OFF in ${formatDuration(lamp.timer)}. Pick a new time or cancel.'
                  : 'The lamp turns ON now and OFF after the time you pick.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final m in presets)
                  ActionChip(
                    label: Text(_label(m)),
                    labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    backgroundColor: colors[1],
                    side: BorderSide.none,
                    onPressed: () => Navigator.pop(context, m),
                  ),
                ActionChip(
                  avatar: Icon(Icons.edit, size: 18, color: colors[1]),
                  label: const Text('Custom'),
                  onPressed: () => _custom(context),
                ),
              ],
            ),
            if (lamp.timer > 0) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.timer_off),
                  label: const Text('Cancel timer (lamp stays ON)'),
                  onPressed: () => Navigator.pop(context, 0),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
