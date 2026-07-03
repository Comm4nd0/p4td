import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/intake_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import 'booking_form_screen.dart';

/// Booking forms submitted through the app. Staff review and approve/deny;
/// owners see the status of their own submissions and can withdraw a pending
/// one or start a new form.
class BookingRequestsScreen extends StatefulWidget {
  final bool isStaff;

  const BookingRequestsScreen({super.key, required this.isStaff});

  @override
  State<BookingRequestsScreen> createState() => _BookingRequestsScreenState();
}

class _BookingRequestsScreenState extends State<BookingRequestsScreen> {
  final DataService _dataService = getIt<DataService>();

  List<IntakeRequest> _requests = [];
  bool _isLoading = true;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    try {
      final requests = await _dataService.getIntakeRequests();
      if (mounted) {
        setState(() {
          _requests = requests;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load booking forms: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _approve(IntakeRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve booking form?'),
        content: Text(
          'This will add ${request.dogNames} to daycare under ${request.ownerName}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _dataService.approveIntakeRequest(request.id);
      _changed = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${request.dogNames} added to daycare'),
            backgroundColor: AppColors.success,
          ),
        );
      }
      _loadRequests();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to approve: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _deny(IntakeRequest request) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deny booking form?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('The owner will be notified that their booking form for ${request.dogNames} was denied.'),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. Fully booked at the moment',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deny'),
          ),
        ],
      ),
    );
    final reason = reasonController.text.trim();
    reasonController.dispose();
    if (confirmed != true) return;

    try {
      await _dataService.denyIntakeRequest(request.id, reason: reason);
      _changed = true;
      _loadRequests();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to deny: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _withdraw(IntakeRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Withdraw booking form?'),
        content: Text('Your booking form for ${request.dogNames} will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _dataService.deleteIntakeRequest(request.id);
      _changed = true;
      _loadRequests();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to withdraw: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _openBookingForm() async {
    final submitted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const BookingFormScreen()),
    );
    if (submitted == true) {
      _changed = true;
      _loadRequests();
    }
  }

  Color _statusColor(IntakeRequestStatus status) {
    switch (status) {
      case IntakeRequestStatus.pending:
        return Colors.orange;
      case IntakeRequestStatus.approved:
        return AppColors.success;
      case IntakeRequestStatus.denied:
        return AppColors.error;
    }
  }

  String _formatDate(DateTime? d) {
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Booking Forms')),
        floatingActionButton: widget.isStaff
            ? null
            : FloatingActionButton.extended(
                onPressed: _openBookingForm,
                icon: Picon(PiconsDuotone.plus),
                label: const Text('New Booking Form'),
              ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _requests.isEmpty
                ? _buildEmptyState()
                : RefreshIndicator.adaptive(
                    onRefresh: _loadRequests,
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _requests.length,
                      itemBuilder: (context, index) => _buildRequestCard(_requests[index]),
                    ),
                  ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Picon(PiconsDuotone.clipboardText, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            widget.isStaff ? 'No booking forms yet' : 'You haven\'t submitted a booking form yet',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          if (!widget.isStaff) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Fill out the booking form to get your dog(s) booked into daycare.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRequestCard(IntakeRequest request) {
    final statusColor = _statusColor(request.status);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        leading: Picon(PiconsDuotone.clipboardText, color: AppColors.primary),
        title: Text(
          widget.isStaff ? '${request.ownerName} — ${request.dogNames}' : request.dogNames,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                request.status.displayName,
                style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDate(request.createdAt),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.isStaff) ...[
            _detailRow('Owner', '${request.ownerName} (${request.ownerEmail})'),
            _detailRow('Phone', request.phoneNumber),
            _detailRow('Address', request.address),
            _detailRow('Postcode', request.postcode),
            _detailRow('Pickup instructions', request.pickupInstructions),
          ],
          _detailRow('Additional info', request.additionalInfo),
          if (request.status == IntakeRequestStatus.denied)
            _detailRow('Reason', request.denialReason),
          if (request.reviewedByName != null)
            _detailRow('Reviewed by', request.reviewedByName),
          const SizedBox(height: 8),
          for (final dog in request.dogs) _buildDogSummary(dog),
          if (request.status == IntakeRequestStatus.pending) ...[
            const SizedBox(height: 8),
            if (widget.isStaff)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _deny(request),
                      icon: const Picon(PiconsDuotone.x, size: 18),
                      label: const Text('Deny'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _approve(request),
                      icon: const Picon(PiconsDuotone.check, size: 18),
                      label: const Text('Approve'),
                    ),
                  ),
                ],
              )
            else
              OutlinedButton.icon(
                onPressed: () => _withdraw(request),
                icon: const Picon(PiconsDuotone.trash, size: 18),
                label: const Text('Withdraw'),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
              ),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildDogSummary(IntakeDog dog) {
    final details = <String>[
      if (dog.sex != null) dog.sex == DogSex.male ? 'Male' : 'Female',
      if (dog.dateOfBirth != null) 'Born ${_formatDate(dog.dateOfBirth)}',
      if (dog.isSpayed) 'Spayed/neutered',
      dog.scheduleType == ScheduleType.adHoc
          ? 'Ad hoc'
          : '${dog.scheduleType.displayName}: ${dog.daysInDaycare.map((d) => d.displayName.substring(0, 3)).join(', ')}',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Picon(PiconsDuotone.pawPrint, size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(dog.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          Text(details.join(' · '), style: const TextStyle(fontSize: 13)),
          if (dog.foodInstructions?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Food: ${dog.foodInstructions}', style: const TextStyle(fontSize: 13)),
            ),
          if (dog.medicalNotes?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Medical: ${dog.medicalNotes}', style: const TextStyle(fontSize: 13)),
            ),
          if (dog.registeredVet?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Vet: ${dog.registeredVet}', style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
