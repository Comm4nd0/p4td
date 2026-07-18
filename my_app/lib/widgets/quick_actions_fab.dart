import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

/// A single entry in a [QuickActionsFab] speed-dial menu.
class QuickFabAction {
  final PiconDuotoneData icon;
  final String label;
  final VoidCallback onPressed;

  /// Accent for the action's mini button icon. Defaults to the theme primary.
  final Color? color;

  const QuickFabAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });
}

/// Expandable "Quick Actions" floating button (speed dial).
///
/// Collapsed it sits at the bottom right as a single extended FAB; tapping it
/// fans out one labelled mini-button per [QuickFabAction] above it. Tapping an
/// action (label or button) collapses the menu and fires its callback. Place
/// it in a [Scaffold.floatingActionButton] slot.
class QuickActionsFab extends StatefulWidget {
  final List<QuickFabAction> actions;

  const QuickActionsFab({super.key, required this.actions});

  @override
  State<QuickActionsFab> createState() => _QuickActionsFabState();
}

class _QuickActionsFabState extends State<QuickActionsFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _expand = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  bool _open = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      if (_open) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  void _run(QuickFabAction action) {
    _toggle();
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // The fan-out menu. SizeTransition keeps the collapsed widget from
        // occupying (and blocking gestures over) the space above the FAB.
        IgnorePointer(
          ignoring: !_open,
          child: SizeTransition(
            sizeFactor: _expand,
            axisAlignment: -1.0,
            child: FadeTransition(
              opacity: _expand,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final action in widget.actions) _buildItem(theme, action),
                ],
              ),
            ),
          ),
        ),
        FloatingActionButton.extended(
          heroTag: null,
          onPressed: _toggle,
          icon: AnimatedRotation(
            turns: _open ? 0.125 : 0, // plus rotates into a close cross
            duration: const Duration(milliseconds: 200),
            child: Picon(PiconsDuotone.plus),
          ),
          label: const Text('Quick Actions'),
        ),
      ],
    );
  }

  Widget _buildItem(ThemeData theme, QuickFabAction action) {
    final accent = action.color ?? theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _run(action),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                action.label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.small(
            heroTag: null,
            onPressed: () => _run(action),
            backgroundColor: theme.colorScheme.surface,
            foregroundColor: accent,
            child: Picon(action.icon, size: 20, color: accent),
          ),
        ],
      ),
    );
  }
}
