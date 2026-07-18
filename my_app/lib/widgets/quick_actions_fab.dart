import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

/// A single entry in a [QuickActionsFab] speed-dial menu.
class QuickFabAction {
  final PiconDuotoneData icon;
  final String label;
  final VoidCallback onPressed;

  /// Accent for the action's icon. Defaults to the theme primary.
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
/// opens an opaque menu card directly above the button (right-aligned with
/// it), one row per [QuickFabAction], so the options stay readable over
/// whatever the screen shows behind them. Tapping a row collapses the menu
/// and fires its callback. Place it in a [Scaffold.floatingActionButton] slot.
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
        // The menu card, anchored to the button's top-right corner so it
        // scales out of the button. Offstage removes it from layout when
        // closed — floating snackbars position themselves above this widget,
        // so the collapsed height must be just the button. (Not
        // SizeTransition: that expands to full width and pins its child to
        // the left edge, which un-anchors the menu from the button.)
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Offstage(
            offstage: _controller.isDismissed,
            child: IgnorePointer(
              ignoring: !_open,
              child: FadeTransition(
                opacity: _expand,
                child: ScaleTransition(
                  scale: _expand,
                  alignment: Alignment.bottomRight,
                  child: child,
                ),
              ),
            ),
          ),
          child: _buildMenuCard(theme),
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

  Widget _buildMenuCard(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        // Solid surface + shadow keeps the options legible over busy content.
        color: theme.colorScheme.surface,
        elevation: 6,
        shadowColor: Colors.black38,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final action in widget.actions) _buildItem(theme, action),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(ThemeData theme, QuickFabAction action) {
    final accent = action.color ?? theme.colorScheme.primary;
    return InkWell(
      onTap: () => _run(action),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Picon(action.icon, size: 20, color: accent),
            const SizedBox(width: 10),
            Text(
              action.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
