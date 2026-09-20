import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/dog_link_request.dart';
import '../models/intake_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/dog_picker_sheet.dart';
import '../widgets/page_body.dart';
import 'booking_form_screen.dart';
import 'link_dog_screen.dart';

/// Both ways a client asks for a dog on their account, reviewed in one place:
/// New Dog Booking Forms (staff approve to create the dog) and Link My Dog
/// requests (staff match to a dog already on the books and approve). Owners
/// see the status of their own and can withdraw a pending one or start
/// another.
class BookingRequestsScreen extends StatefulWidget {
  final bool isStaff;

  const BookingRequestsScreen({super.key, required this.isStaff});

  @override
  State<BookingRequestsScreen> createState() => _BookingRequestsScreenState();
}

class _BookingRequestsScreenState extends State<BookingRequestsScreen> {
  final DataService _dataService = getIt<DataService>();

  List<IntakeRequest> _requests = [];
  List<DogLinkRequest> _linkRequests = [];
  bool _isLoading = true;
  bool _changed = false;
  int? _busyLinkRequestId;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    // Each list fails on its own: a problem with one must not hide the other.
    final results = await Future.wait<Object?>([
      _dataService.getIntakeRequests().then<Object?>((v) => v, onError: (e) => e),
      _dataService.getDogLinkRequests().then<Object?>((v) => v, onError: (e) => e),
    ]);
    if (!mounted) return;
    final errors = results.whereType<Object>().where((r) => r is! List).toList();
    setState(() {
      if (results[0] is List<IntakeRequest>) _requests = results[0] as List<IntakeRequest>;
      if (results[1] is List<DogLinkRequest>) _linkRequests = results[1] as List<DogLinkRequest>;
      _isLoading = false;
    });
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load booking forms: ${errors.first}'), backgroundColor: AppColors.error),
      );
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

  Future<void> _linkTo(DogLinkRequest request, {required int dogId, required String dogName, String? ownerName}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Link this dog?'),
        content: Text(
          ownerName == null
              ? '$dogName will be put on ${request.ownerName}\'s account as the owner.'
              : '$dogName is on the books under $ownerName. ${request.ownerName} will be added as a co-owner and see everything about the dog.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Link'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyLinkRequestId = request.id);
    try {
      await _dataService.approveDogLinkRequest(request.id, dogId: dogId);
      _changed = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$dogName linked to ${request.ownerName}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
      await _loadRequests();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to link: $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _busyLinkRequestId = null);
    }
  }

  /// The suggestions missed: let staff search every dog on the books.
  Future<void> _linkToAnotherDog(DogLinkRequest request) async {
    List<Dog> dogs;
    try {
      dogs = await _dataService.getDogs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load dogs: $e'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (!mounted) return;
    final chosen = await showDogPicker(
      context,
      dogs: dogs,
      title: 'Which dog is ${request.dogName}?',
      subtitle: 'The dog will be linked to ${request.ownerName}\'s account.',
    );
    if (chosen == null || !mounted) return;
    final dogId = int.tryParse(chosen.id);
    if (dogId == null) return;
    await _linkTo(request, dogId: dogId, dogName: chosen.name, ownerName: chosen.ownerDetails?.displayName);
  }

  Future<void> _denyLink(DogLinkRequest request) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deny link request?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${request.ownerName} will be told that ${request.dogName} could not be linked to their account.'),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. We have no dog of that name — please check the spelling',
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
      await _dataService.denyDogLinkRequest(request.id, reason: reason);
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

  Future<void> _withdrawLink(DogLinkRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Withdraw link request?'),
        content: Text('Your request to link ${request.dogName} will be removed.'),
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
      await _dataService.deleteDogLinkRequest(request.id);
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

  Future<void> _openLinkDog() async {
    final submitted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const LinkDogScreen()),
    );
    if (submitted == true) {
      _changed = true;
      _loadRequests();
    }
  }

  /// Owners choose which of the two they need — the wrong one used to hand
  /// staff a duplicate dog.
  Future<void> _chooseWhatToAdd() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Picon(PiconsDuotone.link, color: AppColors.primary),
              title: const Text('Link my dog'),
              subtitle: const Text('My dog already comes to daycare'),
              onTap: () => Navigator.pop(context, 'link'),
            ),
            ListTile(
              leading: Picon(PiconsDuotone.clipboardText, color: AppColors.primary),
              title: const Text('New Dog Booking Form'),
              subtitle: const Text("A dog that hasn't been to Paws 4 Thought before"),
              onTap: () => Navigator.pop(context, 'new'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'link') {
      await _openLinkDog();
    } else if (choice == 'new') {
      await _openBookingForm();
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
                onPressed: _chooseWhatToAdd,
                icon: Picon(PiconsDuotone.plus),
                label: const Text('Add a Dog'),
              ),
        body: PageBody(child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _requests.isEmpty && _linkRequests.isEmpty
                ? _buildEmptyState()
                : RefreshIndicator.adaptive(
                    onRefresh: _loadRequests,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_linkRequests.isNotEmpty) ...[
                          _sectionHeader('Link My Dog requests'),
                          for (final request in _linkRequests) _buildLinkRequestCard(request),
                        ],
                        if (_requests.isNotEmpty) ...[
                          _sectionHeader('New Dog Booking Forms'),
                          for (final request in _requests) _buildRequestCard(request),
                        ],
                      ],
                    ),
                  )),
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
            widget.isStaff ? 'No booking forms or link requests yet' : 'Nothing here yet',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          if (!widget.isStaff) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Already come to daycare? Link your dog to this account. '
                'Bringing a new dog? Fill out the New Dog Booking Form.',
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
            _detailRow('Emergency contact', request.emergencyContactNumber),
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

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.grey[600],
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildLinkRequestCard(DogLinkRequest request) {
    final statusColor = _statusColor(request.status);
    final pending = request.status == IntakeRequestStatus.pending;
    final busy = _busyLinkRequestId == request.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        initiallyExpanded: widget.isStaff && pending,
        leading: Picon(PiconsDuotone.link, color: AppColors.primary),
        title: Text(
          widget.isStaff ? '${request.ownerName} — ${request.dogName}' : request.dogName,
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
            _detailRow('Dog', request.dogName),
            _detailRow('Postcode', request.postcode),
            _detailRow('Phone', request.phoneNumber),
          ],
          _detailRow('Notes', request.notes),
          if (request.status == IntakeRequestStatus.approved)
            _detailRow('Linked to', request.linkedDogName),
          if (request.status == IntakeRequestStatus.denied)
            _detailRow('Reason', request.denialReason),
          if (request.reviewedByName != null)
            _detailRow('Reviewed by', request.reviewedByName),
          if (pending && widget.isStaff) ...[
            const SizedBox(height: 8),
            Text(
              request.candidates?.isEmpty ?? true
                  ? 'No dog on the books matches. Search for it below, or deny.'
                  : 'Dogs on the books that match — tap Link on the right one:',
              style: TextStyle(fontSize: 13, color: Colors.grey[700]),
            ),
            const SizedBox(height: 6),
            for (final candidate in request.candidates ?? const <LinkCandidate>[])
              _buildCandidateTile(request, candidate, busy: busy),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => _denyLink(request),
                    icon: const Picon(PiconsDuotone.x, size: 18),
                    label: const Text('Deny'),
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => _linkToAnotherDog(request),
                    icon: const Picon(PiconsDuotone.magnifyingGlass, size: 18),
                    label: const Text('Find dog'),
                  ),
                ),
              ],
            ),
          ] else if (pending) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _withdrawLink(request),
              icon: const Picon(PiconsDuotone.trash, size: 18),
              label: const Text('Withdraw'),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCandidateTile(DogLinkRequest request, LinkCandidate candidate, {required bool busy}) {
    final labels = candidate.matchLabels;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: DogPickerAvatar(imageUrl: candidate.profileImageUrl),
        title: Text(candidate.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              candidate.ownerName == null
                  ? 'No owner on the app${candidate.postcode?.isNotEmpty ?? false ? ' · ${candidate.postcode}' : ''}'
                  : 'Owner: ${candidate.ownerName}',
              style: const TextStyle(fontSize: 12),
            ),
            if (labels.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final label in labels)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.success.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$label matches',
                          style: const TextStyle(fontSize: 10, color: AppColors.success, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        trailing: ElevatedButton(
          onPressed: busy
              ? null
              : () => _linkTo(request, dogId: candidate.id, dogName: candidate.name, ownerName: candidate.ownerName),
          child: const Text('Link'),
        ),
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
          // The form asks for the certificate; a missing one is worth a word
          // with the owner before approving, so it reads red.
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Picon(
                  dog.hasCertificate ? PiconsDuotone.certificate : PiconsDuotone.warningCircle,
                  size: 16,
                  color: dog.hasCertificate ? AppColors.success : AppColors.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    dog.hasCertificate
                        ? 'Certificate attached: ${dog.certificateFilename}'
                            '${dog.lastVaccinationDate != null ? ' (vaccinated ${_formatDate(dog.lastVaccinationDate)})' : ''}'
                        : 'No vaccination certificate attached',
                    style: TextStyle(
                      fontSize: 13,
                      color: dog.hasCertificate ? null : AppColors.error,
                      fontWeight: dog.hasCertificate ? null : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
