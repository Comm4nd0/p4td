import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/roadwork_issue.dart';

/// Colour for a severity, shared by the banner, the dashboard ring and the map
/// pins so the same issue reads the same everywhere.
Color roadworkSeverityColor(RoadworkSeverity severity) => switch (severity) {
      RoadworkSeverity.high => AppColors.error,
      RoadworkSeverity.medium => Colors.orange.shade700,
      RoadworkSeverity.low => Colors.amber.shade700,
    };

/// Summary of the roadworks on one staff member's route, shown above their dog
/// list so a driver sees what's in the way before they read the running order.
///
/// Renders nothing when the route is clear — no "all clear" row, which would
/// just be noise on every other day.
class RoadworkBanner extends StatelessWidget {
  const RoadworkBanner({super.key, required this.issues});

  /// Already filtered to the relevant staff member and sorted worst-first.
  final List<RoadworkIssue> issues;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) return const SizedBox.shrink();

    final worst = issues.first.severity;
    final color = roadworkSeverityColor(worst);
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Picon(PiconsDuotone.warning, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    issues.length == 1
                        ? '1 roadwork on this route'
                        : '${issues.length} roadworks on this route',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...issues.map((issue) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 5, right: 8),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: roadworkSeverityColor(issue.severity),
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              issue.locationLabel,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              [
                                if (issue.severityLabel.isNotEmpty) issue.severityLabel,
                                if (issue.description.isNotEmpty) issue.description,
                              ].join(' — '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
