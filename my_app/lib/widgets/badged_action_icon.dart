import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';

/// An AppBar action icon with an unread count pinned to its corner — the
/// bell and the three inbox icons (Contact Staff, Booking Forms, Website
/// Inquiries) on the staff home screen.
///
/// The badge is only drawn when [count] is above zero, and caps at "99+" so
/// a backlog can't push the icon out of the row. The tooltip carries the
/// count too, so a screen reader announces "Booking Forms, 3 unread".
class BadgedActionIcon extends StatelessWidget {
  final PiconDuotoneData icon;
  final int count;
  final String tooltip;
  final VoidCallback onPressed;

  const BadgedActionIcon({
    super.key,
    required this.icon,
    required this.count,
    required this.tooltip,
    required this.onPressed,
  });

  /// "99+" beyond two digits — the pill has to stay a pill.
  static String badgeLabel(int count) => count > 99 ? '99+' : '$count';

  @override
  Widget build(BuildContext context) {
    final semanticLabel = count > 0 ? '$tooltip, $count unread' : tooltip;
    return Semantics(
      label: semanticLabel,
      button: true,
      child: ExcludeSemantics(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              icon: Picon(icon),
              tooltip: tooltip,
              onPressed: onPressed,
              // Four inbox icons plus the bell have to share a phone-width
              // AppBar with the logo, so each takes a little less than the
              // 48px Material default while keeping a 40px tap target.
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: const EdgeInsets.all(6),
            ),
            if (count > 0)
              Positioned(
                right: 0,
                top: 2,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: AppColors.error,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Theme.of(context).appBarTheme.backgroundColor ??
                            Theme.of(context).colorScheme.surface,
                        width: 1.5,
                      ),
                    ),
                    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                    child: Center(
                      child: Text(
                        badgeLabel(count),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          height: 1.6,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
