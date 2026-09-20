import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';

/// One thing on the screen that needs doing right now: which widget it is,
/// what to say beside it, and what tapping it does.
class SpotlightStep {
  final String id;
  final GlobalKey targetKey;
  final String title;
  final String message;
  final String actionLabel;
  final Future<void> Function() onAction;

  const SpotlightStep({
    required this.id,
    required this.targetKey,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });
}

/// Dims everything except one widget and points a speech bubble at it.
///
/// Laid over a screen (a `Positioned.fill` in a `Stack` above it), the
/// overlay scrolls the target into view, cuts a hole in a dark scrim around
/// it, and shows a bubble with the message, a Not now link and the action.
/// Tapping inside the hole is the same as the action button. Everything
/// else is blocked, so the step has to be dealt with or put off; the parent
/// decides which step is current and removes the overlay when none is left.
class SpotlightOverlay extends StatefulWidget {
  final SpotlightStep step;

  /// How many more steps follow this one, for the "1 of 3" hint.
  final int remaining;
  final VoidCallback onNotNow;

  const SpotlightOverlay({
    super.key,
    required this.step,
    this.remaining = 0,
    required this.onNotNow,
  });

  @override
  State<SpotlightOverlay> createState() => _SpotlightOverlayState();
}

class _SpotlightOverlayState extends State<SpotlightOverlay> {
  Rect? _hole;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _locate(scroll: true);
  }

  @override
  void didUpdateWidget(SpotlightOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step.id != widget.step.id) {
      _hole = null;
      _locate(scroll: true);
    }
  }

  /// Finds the target after the next frame, scrolling it into view first if
  /// asked. Re-run every frame while showing so a re-layout underneath
  /// (a reload, a rotation) keeps the hole on the widget.
  void _locate({required bool scroll}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final targetContext = widget.step.targetKey.currentContext;
      if (targetContext == null) return;
      if (scroll) {
        await Scrollable.ensureVisible(
          targetContext,
          alignment: 0.25,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
        if (!mounted) return;
      }
      final target = targetContext.findRenderObject();
      final own = context.findRenderObject();
      if (target is! RenderBox || own is! RenderBox || !target.attached || !own.attached) return;
      final topLeft = target.localToGlobal(Offset.zero) - own.localToGlobal(Offset.zero);
      final rect = (topLeft & target.size).inflate(6);
      if (_hole != rect) setState(() => _hole = rect);
    });
  }

  Future<void> _act() async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await widget.step.onAction();
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Track the widget underneath: cheap, and it keeps the hole honest.
    _locate(scroll: false);
    final hole = _hole;
    final size = MediaQuery.of(context).size;
    final theme = Theme.of(context);

    // Bubble below the hole when there's room, else above it.
    final bubbleWidth = (size.width - 32).clamp(200.0, 380.0);
    double? top;
    double? bottom;
    bool pointsUp = true;
    if (hole != null) {
      if (hole.bottom + 180 < size.height) {
        top = hole.bottom + 14;
      } else {
        bottom = size.height - hole.top + 14;
        pointsUp = false;
      }
    }
    final left = hole == null
        ? 16.0
        : (hole.center.dx - bubbleWidth / 2).clamp(16.0, size.width - bubbleWidth - 16);
    final pointerX = hole == null ? bubbleWidth / 2 : (hole.center.dx - left).clamp(24.0, bubbleWidth - 24);

    return AnimatedOpacity(
      opacity: hole == null ? 0 : 1,
      duration: const Duration(milliseconds: 200),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                if (hole != null && hole.contains(details.localPosition)) _act();
              },
              child: CustomPaint(painter: _ScrimPainter(hole)),
            ),
          ),
          if (hole != null)
            Positioned(
              left: left,
              top: top,
              bottom: bottom,
              width: bubbleWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (pointsUp) _pointer(pointerX, up: true, color: theme.colorScheme.surface),
                  Material(
                    color: theme.colorScheme.surface,
                    elevation: 8,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(children: [
                            const Picon(PiconsDuotone.warningCircle, size: 18, color: AppColors.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(widget.step.title,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                            ),
                            if (widget.remaining > 0)
                              Text('+${widget.remaining} more',
                                  style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                          ]),
                          const SizedBox(height: 6),
                          Text(widget.step.message, style: const TextStyle(fontSize: 13)),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: _acting ? null : widget.onNotNow,
                                child: const Text('Not now'),
                              ),
                              const SizedBox(width: 4),
                              FilledButton(
                                onPressed: _acting ? null : _act,
                                child: Text(widget.step.actionLabel),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!pointsUp) _pointer(pointerX, up: false, color: theme.colorScheme.surface),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _pointer(double x, {required bool up, required Color color}) {
    return SizedBox(
      height: 10,
      child: CustomPaint(
        painter: _PointerPainter(x: x, up: up, color: color),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Dark scrim with a rounded hole cut out of it.
class _ScrimPainter extends CustomPainter {
  final Rect? hole;
  _ScrimPainter(this.hole);

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Path()..addRect(Offset.zero & size);
    final path = hole == null
        ? scrim
        : Path.combine(
            PathOperation.difference,
            scrim,
            Path()..addRRect(RRect.fromRectAndRadius(hole!, const Radius.circular(14))),
          );
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.7));
    if (hole != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(hole!, const Radius.circular(14)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.hole != hole;
}

/// The little triangle joining the bubble to the hole.
class _PointerPainter extends CustomPainter {
  final double x;
  final bool up;
  final Color color;
  _PointerPainter({required this.x, required this.up, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (up) {
      path
        ..moveTo(x - 10, size.height)
        ..lineTo(x, 0)
        ..lineTo(x + 10, size.height);
    } else {
      path
        ..moveTo(x - 10, 0)
        ..lineTo(x, size.height)
        ..lineTo(x + 10, 0);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PointerPainter old) => old.x != x || old.up != up || old.color != color;
}
