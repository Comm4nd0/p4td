import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/boarding_request.dart';
import '../utils/date_formats.dart';
import 'request_timeline.dart';

/// Full boarding-request card shared by the staff dashboard tab and the
/// Manage Boarding screen: header, dates, carer, instructions, timeline,
/// plus the management actions (approve/deny/set pending/edit/delete) when
/// the viewer can manage requests, or edit/cancel for an owner's own
/// pending request. An approved stay the owner wants to move shows their
/// requested dates, with approve/decline for managers and request/withdraw
/// for the owner.
class BoardingRequestCard extends StatelessWidget {
  final BoardingRequest request;

  /// Show the "Owner: …" line (staff views).
  final bool showOwner;

  /// Viewer has the can_manage_requests permission — shows the full staff
  /// action row.
  final bool canManage;

  final VoidCallback? onApprove;
  final VoidCallback? onDeny;
  final VoidCallback? onSetPending;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;

  /// Owner withdrawing their own pending request (delete with confirm handled
  /// by the caller). Only rendered while the request is pending.
  final VoidCallback? onCancel;

  /// Owner asking to move an approved stay's dates (or editing that ask).
  final VoidCallback? onRequestChange;

  /// Owner taking back their pending date-change request.
  final VoidCallback? onWithdrawChange;

  /// Boarding manager approving / declining the owner's requested dates.
  final VoidCallback? onApproveChange;
  final VoidCallback? onDenyChange;

  const BoardingRequestCard({
    super.key,
    required this.request,
    this.showOwner = false,
    this.canManage = false,
    this.onApprove,
    this.onDeny,
    this.onSetPending,
    this.onDelete,
    this.onEdit,
    this.onCancel,
    this.onRequestChange,
    this.onWithdrawChange,
    this.onApproveChange,
    this.onDenyChange,
  });

  @override
  Widget build(BuildContext context) {
    // A requested date change needs a manager just like a new request does.
    final isPending = request.status == BoardingRequestStatus.pending || request.hasPendingChange;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      // Highlight pending requests with a colored border
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isPending ? BorderSide(color: Colors.orange.shade300, width: 2) : BorderSide.none,
      ),
      elevation: isPending ? 4 : 1,
      surfaceTintColor: isPending ? Colors.orange.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Picon(PiconsDuotone.bed, size: 20, color: AppColors.primaryDark),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.dogNames.join(', '),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      if (showOwner)
                        Text(
                          'Owner: ${request.ownerName}',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    BoardingStatusBadge(status: request.status),
                    if (request.status != BoardingRequestStatus.pending && request.approvedByName != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          'by ${request.approvedByName}',
                          style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const Divider(height: 24),
            // Dates
            Row(
              children: [
                Picon(PiconsDuotone.calendarDots, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${ukDateWithDay(request.startDate)} - ${ukDateWithDay(request.endDate)}',
                        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                      ),
                      Text(
                        '${request.endDate.difference(request.startDate).inDays} nights',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (request.assignedStaffName != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Picon(PiconsDuotone.user, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text('Boarding with ${request.assignedStaffName}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                ],
              ),
            ],
            if (request.specialInstructions != null && request.specialInstructions!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Instructions:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                    Text(request.specialInstructions!, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ],
            if (request.hasPendingChange) ...[
              const SizedBox(height: 12),
              _buildChangeRequest(),
            ],
            const SizedBox(height: 12),
            RequestTimeline(
              status: request.status.toString().split('.').last,
              createdAt: request.createdAt,
              resolvedAt: request.approvedAt,
              resolvedBy: request.approvedByName,
            ),
            if (canManage) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  if (onDelete != null)
                    IconButton(
                      onPressed: onDelete,
                      icon: Picon(PiconsDuotone.trash, size: 20, color: Colors.red[700]),
                      tooltip: 'Delete booking',
                      visualDensity: VisualDensity.compact,
                    ),
                  if (onEdit != null)
                    IconButton(
                      onPressed: onEdit,
                      icon: Picon(PiconsDuotone.pencilSimple, size: 20, color: AppColors.primary),
                      tooltip: 'Edit dates & instructions',
                      visualDensity: VisualDensity.compact,
                    ),
                  const Spacer(),
                  // While the owner's date change is waiting, its own
                  // Decline / Approve change are the only decisions shown —
                  // a stay-level Deny beside them would deny the whole booking.
                  if (!request.hasPendingChange &&
                      request.status != BoardingRequestStatus.pending &&
                      onSetPending != null)
                    TextButton(
                      onPressed: onSetPending,
                      child: const Text('Set Pending'),
                    ),
                  if (!request.hasPendingChange &&
                      request.status != BoardingRequestStatus.denied &&
                      onDeny != null)
                    OutlinedButton(
                      onPressed: onDeny,
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Deny'),
                    ),
                  const SizedBox(width: 8),
                  if (request.status != BoardingRequestStatus.approved && onApprove != null)
                    FilledButton(
                      onPressed: onApprove,
                      child: const Text('Approve'),
                    ),
                ],
              ),
            ] else if (request.status == BoardingRequestStatus.approved &&
                request.isUnfinished &&
                (onRequestChange != null || onWithdrawChange != null)) ...[
              // Owner's approved stay: ask staff to move the dates.
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (request.hasPendingChange && onWithdrawChange != null)
                    TextButton(
                      onPressed: onWithdrawChange,
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Withdraw change'),
                    ),
                  const SizedBox(width: 8),
                  if (onRequestChange != null)
                    OutlinedButton.icon(
                      onPressed: onRequestChange,
                      icon: Picon(PiconsDuotone.calendarDots, size: 18),
                      label: Text(request.hasPendingChange ? 'Edit change' : 'Change dates'),
                    ),
                ],
              ),
            ] else if (request.status == BoardingRequestStatus.pending &&
                (onEdit != null || onCancel != null)) ...[
              // Owner's own pending request: they can still amend or withdraw it.
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onEdit != null)
                    TextButton.icon(
                      onPressed: onEdit,
                      icon: Picon(PiconsDuotone.pencilSimple, size: 18),
                      label: const Text('Edit'),
                    ),
                  const SizedBox(width: 8),
                  if (onCancel != null)
                    OutlinedButton(
                      onPressed: onCancel,
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Cancel request'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

extension on BoardingRequestCard {
  /// The owner's requested dates beside the booked ones, with the manager's
  /// approve/decline when they can act on it.
  Widget _buildChangeRequest() {
    final start = request.requestedStartDate!;
    final end = request.requestedEndDate!;
    final nights = end.difference(start).inDays;
    final note = request.changeNote;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Picon(PiconsDuotone.arrowsClockwise, size: 16, color: Colors.orange.shade800),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  canManage && request.changeRequestedByName != null
                      ? '${request.changeRequestedByName} asked to change the dates'
                      : 'Date change requested — awaiting approval',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.orange.shade900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${ukDateWithDay(start)} - ${ukDateWithDay(end)}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          Text(
            '$nights night${nights == 1 ? '' : 's'} (booked: ${ukDate(request.startDate)} - ${ukDate(request.endDate)})',
            style: TextStyle(color: Colors.grey[700], fontSize: 12),
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('"$note"', style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
          ],
          if (canManage && (onApproveChange != null || onDenyChange != null)) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onDenyChange != null)
                  OutlinedButton(
                    onPressed: onDenyChange,
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                    child: const Text('Decline change'),
                  ),
                const SizedBox(width: 8),
                if (onApproveChange != null)
                  FilledButton(
                    onPressed: onApproveChange,
                    child: const Text('Approve change'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Ask a manager for an optional reason before declining an owner's date
/// change. Returns null when they back out, otherwise the (possibly empty)
/// reason, which is added to the owner's push.
Future<String?> promptBoardingChangeDeclineReason(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Decline date change?'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(
          labelText: 'Reason for the owner (optional)',
          hintText: "e.g. We're fully booked that weekend",
        ),
        maxLines: 2,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Decline'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// Pill badge showing a boarding request's status in its status colour.
class BoardingStatusBadge extends StatelessWidget {
  final BoardingRequestStatus status;

  const BoardingStatusBadge({super.key, required this.status});

  static Color colorFor(BoardingRequestStatus status) {
    switch (status) {
      case BoardingRequestStatus.approved:
        return Colors.green;
      case BoardingRequestStatus.denied:
        return Colors.red;
      case BoardingRequestStatus.pending:
        return Colors.orange;
      case BoardingRequestStatus.cancelled:
        return Colors.grey;
    }
  }

  static String labelFor(BoardingRequestStatus status) {
    switch (status) {
      case BoardingRequestStatus.approved:
        return 'Approved';
      case BoardingRequestStatus.denied:
        return 'Denied';
      case BoardingRequestStatus.pending:
        return 'Pending';
      case BoardingRequestStatus.cancelled:
        return 'Cancelled';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        labelFor(status),
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}
