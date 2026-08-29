import 'package:flutter/material.dart';

/// Caps a screen body's width on large screens (tablet / desktop) so
/// single-column content — lists, forms, detail pages — doesn't stretch
/// edge-to-edge. On phones the constraint never binds, so wrapped screens
/// are unchanged there.
///
/// Wrap the Scaffold `body` of any pushed single-column screen in this.
/// Screens that genuinely want the full width (the pickup map, the day
/// board, the dashboard's two-pane layout, photo grids) should NOT use it.
class PageBody extends StatelessWidget {
  const PageBody({super.key, this.maxWidth = 720, required this.child});

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Top-aligned (not Center) so short content keeps its phone position
    // instead of floating to the vertical middle.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
