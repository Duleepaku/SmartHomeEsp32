import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// Colourful card for one lamp. Tap = ON/OFF, long press = menu.
class LampCard extends StatelessWidget {
  const LampCard({
    super.key,
    required this.lamp,
    required this.busy,
    required this.onTap,
    required this.onTimer,
    required this.onLongPress,
  });

  final Lamp lamp;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onTimer;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final colors = AppTheme.lampGradient(lamp.id);
    final on = lamp.on;
    final fg = on ? Colors.white : cs.onSurface;
    final radius = BorderRadius.circular(22);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        gradient: on
            ? LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: on ? null : cs.surface,
        borderRadius: radius,
        border: on ? null : Border.all(color: colors[0].withAlpha(110), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: on ? colors[1].withAlpha(120) : Colors.black.withAlpha(20),
            blurRadius: on ? 18 : 6,
            offset: Offset(0, on ? 6 : 2),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: busy ? null : onTap,
          onLongPress: busy ? null : onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: on ? Colors.white.withAlpha(60) : colors[0].withAlpha(35),
                        boxShadow: on
                            ? [BoxShadow(color: Colors.white.withAlpha(90), blurRadius: 14)]
                            : null,
                      ),
                      child: Icon(
                        on ? Icons.lightbulb : Icons.lightbulb_outline,
                        color: on ? Colors.white : colors[1],
                        size: 26,
                      ),
                    ),
                    const Spacer(),
                    if (busy)
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                      )
                    else
                      Text(
                        '#${lamp.id}',
                        style: TextStyle(
                          color: fg.withAlpha(150),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                Text(
                  lamp.name,
                  maxLines: lamp.schEnabled ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (lamp.schEnabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Icon(Icons.schedule, size: 13, color: on ? Colors.white70 : colors[1]),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            lamp.scheduleText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: on ? Colors.white70 : colors[1],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      on ? 'ON' : 'OFF',
                      style: TextStyle(
                        color: on ? Colors.white.withAlpha(220) : colors[1],
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                    const Spacer(),
                    _TimerButton(lamp: lamp, color: colors[1], onTap: onTimer),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TimerButton extends StatelessWidget {
  const _TimerButton({required this.lamp, required this.color, required this.onTap});

  final Lamp lamp;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = lamp.timer > 0;
    final bg = lamp.on ? Colors.white.withAlpha(active ? 70 : 40) : color.withAlpha(30);
    final fg = lamp.on ? Colors.white : color;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: active ? 10 : 7, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? Icons.timer : Icons.timer_outlined, size: 16, color: fg),
            if (active) ...[
              const SizedBox(width: 4),
              Text(
                formatDuration(lamp.timer),
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
