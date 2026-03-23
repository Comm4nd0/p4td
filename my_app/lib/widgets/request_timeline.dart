import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/app_colors.dart';

/// A horizontal 3-step timeline showing the lifecycle of a request:
/// Submitted → Under Review → Approved / Denied.
class RequestTimeline extends StatelessWidget {
  /// 'PENDING', 'APPROVED', or 'DENIED' (or the lowercase enum name).
  final String status;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? resolvedBy;

  const RequestTimeline({
    super.key,
    required this.status,
    required this.createdAt,
    this.resolvedAt,
    this.resolvedBy,
  });

  bool get _isPending =>
      status.toUpperCase() == 'PENDING' || status == 'pending';
  bool get _isApproved =>
      status.toUpperCase() == 'APPROVED' || status == 'approved';
  bool get _isDenied =>
      status.toUpperCase() == 'DENIED' || status == 'denied';
  bool get _isResolved => _isApproved || _isDenied;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFmt = DateFormat('d MMM, HH:mm');

    final activeColor = AppColors.primary;
    final deniedColor = AppColors.error;
    final inactiveColor = theme.brightness == Brightness.dark
        ? Colors.grey[700]!
        : Colors.grey[300]!;
    final activeTextColor = theme.colorScheme.onSurface;
    final inactiveTextColor = theme.brightness == Brightness.dark
        ? Colors.grey[500]!
        : Colors.grey[500]!;

    // Step 3 color depends on approved vs denied
    final step3Color =
        _isDenied ? deniedColor : (_isApproved ? activeColor : inactiveColor);
    final step3TextColor = _isResolved ? activeTextColor : inactiveTextColor;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // Step 1: Submitted (always active)
          _buildStep(
            color: activeColor,
            icon: Icons.send,
            label: 'Submitted',
            detail: dateFmt.format(createdAt),
            labelColor: activeTextColor,
            detailColor: inactiveTextColor,
          ),
          // Connector 1→2
          Expanded(child: Container(height: 2, color: activeColor)),
          // Step 2: Under Review
          _buildStep(
            color: _isPending ? activeColor : inactiveColor,
            icon: Icons.hourglass_top,
            label: _isPending ? 'Under Review' : 'Reviewed',
            detail: _isPending ? 'Awaiting review' : '',
            labelColor: _isPending ? activeTextColor : inactiveTextColor,
            detailColor: inactiveTextColor,
          ),
          // Connector 2→3
          Expanded(
            child: Container(
              height: 2,
              color: _isResolved ? step3Color : inactiveColor,
            ),
          ),
          // Step 3: Approved / Denied / Pending
          _buildStep(
            color: step3Color,
            icon: _isDenied
                ? Icons.cancel
                : (_isApproved ? Icons.check_circle : Icons.circle_outlined),
            label: _isDenied
                ? 'Denied'
                : (_isApproved ? 'Approved' : 'Pending'),
            detail: _isResolved
                ? (resolvedBy != null ? 'by $resolvedBy' : (resolvedAt != null ? dateFmt.format(resolvedAt!) : ''))
                : '',
            labelColor: step3TextColor,
            detailColor: inactiveTextColor,
          ),
        ],
      ),
    );
  }

  Widget _buildStep({
    required Color color,
    required IconData icon,
    required String label,
    required String detail,
    required Color labelColor,
    required Color detailColor,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: labelColor),
          textAlign: TextAlign.center,
        ),
        if (detail.isNotEmpty)
          Text(
            detail,
            style: TextStyle(fontSize: 9, color: detailColor),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}
