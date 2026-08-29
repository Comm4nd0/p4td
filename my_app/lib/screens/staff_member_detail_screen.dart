import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/staff_hr.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/page_body.dart';

/// Everything a manager needs about one staff member, in five tabs:
/// Overview (employment, holiday, emergency contact, private notes),
/// Pay (rate history), Meetings, Appraisals, and Records (sickness +
/// training). All data comes from the manager-only staff HR endpoints.
class StaffMemberDetailScreen extends StatefulWidget {
  final int staffId;
  final String staffName;

  const StaffMemberDetailScreen({
    super.key,
    required this.staffId,
    required this.staffName,
  });

  @override
  State<StaffMemberDetailScreen> createState() =>
      _StaffMemberDetailScreenState();
}

class _StaffMemberDetailScreenState extends State<StaffMemberDetailScreen> {
  final DataService _dataService = getIt<DataService>();

  StaffHrRecord? _record;
  List<StaffPayRate> _payRates = [];
  List<StaffMeeting> _meetings = [];
  List<StaffAppraisal> _appraisals = [];
  List<SicknessAbsence> _absences = [];
  List<StaffTrainingRecord> _training = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _dataService.getStaffHrRecord(widget.staffId),
        _dataService.getStaffPayRates(widget.staffId),
        _dataService.getStaffMeetings(staffId: widget.staffId),
        _dataService.getStaffAppraisals(staffId: widget.staffId),
        _dataService.getSicknessAbsences(staffId: widget.staffId),
        _dataService.getStaffTrainingRecords(staffId: widget.staffId),
      ]);
      if (!mounted) return;
      setState(() {
        _record = results[0] as StaffHrRecord;
        _payRates = results[1] as List<StaffPayRate>;
        _meetings = results[2] as List<StaffMeeting>;
        _appraisals = results[3] as List<StaffAppraisal>;
        _absences = results[4] as List<SicknessAbsence>;
        _training = results[5] as List<StaffTrainingRecord>;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    try {
      await action();
      await _load();
    } catch (e) {
      _snack('$failure: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.staffName),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Pay'),
              Tab(text: 'Meetings'),
              Tab(text: 'Appraisals'),
              Tab(text: 'Records'),
            ],
          ),
        ),
        body: PageBody(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: () {
                              setState(() => _loading = true);
                              _load();
                            },
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : TabBarView(
                    children: [
                      _buildOverviewTab(),
                      _buildPayTab(),
                      _buildMeetingsTab(),
                      _buildAppraisalsTab(),
                      _buildRecordsTab(),
                    ],
                  )),
      ),
    );
  }

  // ---------- Overview ----------

  Widget _buildOverviewTab() {
    final record = _record!;
    final holiday = record.holiday;
    return RefreshIndicator.adaptive(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          _sectionCard(
            title: 'Employment',
            icon: PiconsDuotone.briefcase,
            onEdit: _editEmployment,
            children: [
              _infoRow('Job title',
                  record.jobTitle.isEmpty ? 'Not set' : record.jobTitle),
              _infoRow(
                  'Started',
                  record.employmentStartDate != null
                      ? _formatDate(record.employmentStartDate!)
                      : 'Not set'),
              if (record.employmentEndDate != null)
                _infoRow('Left', _formatDate(record.employmentEndDate!)),
            ],
          ),
          if (holiday != null)
            _sectionCard(
              title: 'Holiday · ${holiday.year}',
              icon: PiconsDuotone.sunHorizon,
              children: [
                _infoRow('Allowance',
                    '${_trimZero(holiday.allowanceDays ?? 0)} days'),
                _infoRow('Taken / booked', '${holiday.usedDays} days'),
                _infoRow(
                    'Remaining',
                    holiday.remainingDays != null
                        ? '${_trimZero(holiday.remainingDays!)} days'
                        : '—'),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Counted from approved day-off requests. Approvals live in My Availability.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          _sectionCard(
            title: 'Emergency contact',
            icon: PiconsDuotone.firstAidKit,
            onEdit: _editEmployment,
            children: [
              if (record.emergencyContactName.isEmpty)
                _infoRow('Contact', 'Not set')
              else ...[
                _infoRow('Name', record.emergencyContactName),
                if (record.emergencyContactPhone.isNotEmpty)
                  _infoRow('Phone', record.emergencyContactPhone),
                if (record.emergencyContactRelationship.isNotEmpty)
                  _infoRow('Relationship', record.emergencyContactRelationship),
              ],
            ],
          ),
          _sectionCard(
            title: 'Manager notes',
            icon: PiconsDuotone.notePencil,
            onEdit: _editEmployment,
            children: [
              Text(
                record.managerNotes.isEmpty
                    ? 'Nothing recorded. Only managers can see these notes.'
                    : record.managerNotes,
                style: record.managerNotes.isEmpty
                    ? TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editEmployment() async {
    final record = _record!;
    final jobTitle = TextEditingController(text: record.jobTitle);
    final allowance = TextEditingController(text: record.holidayAllowanceDays);
    final ecName = TextEditingController(text: record.emergencyContactName);
    final ecPhone = TextEditingController(text: record.emergencyContactPhone);
    final ecRel =
        TextEditingController(text: record.emergencyContactRelationship);
    final notes = TextEditingController(text: record.managerNotes);
    DateTime? startDate = record.employmentStartDate;
    DateTime? endDate = record.employmentEndDate;

    final saved = await _showFormSheet(
      title: 'Edit employment details',
      builder: (context, setSheetState) => [
        TextField(
          controller: jobTitle,
          decoration: const InputDecoration(labelText: 'Job title'),
        ),
        _datePickerTile(
          label: 'Employment start',
          value: startDate,
          onPicked: (d) => setSheetState(() => startDate = d),
        ),
        _datePickerTile(
          label: 'Employment end (leavers only)',
          value: endDate,
          onPicked: (d) => setSheetState(() => endDate = d),
          allowClear: true,
          onCleared: () => setSheetState(() => endDate = null),
        ),
        TextField(
          controller: allowance,
          decoration: const InputDecoration(
            labelText: 'Holiday allowance (days per year)',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        TextField(
          controller: ecName,
          decoration: const InputDecoration(labelText: 'Emergency contact name'),
        ),
        TextField(
          controller: ecPhone,
          decoration:
              const InputDecoration(labelText: 'Emergency contact phone'),
          keyboardType: TextInputType.phone,
        ),
        TextField(
          controller: ecRel,
          decoration: const InputDecoration(labelText: 'Relationship'),
        ),
        TextField(
          controller: notes,
          decoration: const InputDecoration(
            labelText: 'Manager notes (private)',
            alignLabelWithHint: true,
          ),
          maxLines: 4,
        ),
      ],
    );
    if (saved != true) return;

    await _run(
      () => _dataService.updateStaffHrRecord(record.id, {
        'job_title': jobTitle.text.trim(),
        'employment_start_date': _isoOrNull(startDate),
        'employment_end_date': _isoOrNull(endDate),
        'holiday_allowance_days': allowance.text.trim().isEmpty
            ? '28'
            : allowance.text.trim(),
        'emergency_contact_name': ecName.text.trim(),
        'emergency_contact_phone': ecPhone.text.trim(),
        'emergency_contact_relationship': ecRel.text.trim(),
        'manager_notes': notes.text.trim(),
      }),
      'Failed to save employment details',
    );
  }

  // ---------- Pay ----------

  Widget _buildPayTab() {
    final current = _record?.currentPay;
    return _listTab(
      addLabel: 'New pay rate',
      onAdd: _addPayRate,
      children: [
        if (current != null)
          _sectionCard(
            title: 'Current pay',
            icon: PiconsDuotone.currencyGbp,
            children: [
              Text(
                '£${current.rate} ${current.payTypeLabel}',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              Text(
                'Since ${_formatDate(current.effectiveFrom)}'
                '${current.note.isNotEmpty ? ' · ${current.note}' : ''}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        if (_payRates.isEmpty)
          _emptyNote('No pay set yet. Add the first rate below.'),
        if (_payRates.isNotEmpty) _sectionHeader('History'),
        ..._payRates.map(
          (rate) => Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.primary.withAlpha(30),
                child: const Picon(PiconsDuotone.currencyGbp,
                    color: AppColors.primary, size: 20),
              ),
              title: Text('£${rate.rate} ${rate.payTypeLabel}'),
              subtitle: Text(
                'From ${_formatDate(rate.effectiveFrom)}'
                '${rate.note.isNotEmpty ? ' · ${rate.note}' : ''}'
                '${rate.createdByName != null ? '\nSet by ${rate.createdByName}' : ''}',
              ),
              isThreeLine: rate.createdByName != null,
              trailing: IconButton(
                icon: const Picon(PiconsDuotone.trash, size: 20),
                onPressed: () => _confirmDelete(
                  'Delete this pay rate?',
                  () => _dataService.deleteStaffPayRate(rate.id),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _addPayRate() async {
    final rate = TextEditingController();
    final note = TextEditingController();
    String payType = 'HOURLY';
    DateTime effectiveFrom = DateTime.now();

    final saved = await _showFormSheet(
      title: 'New pay rate',
      builder: (context, setSheetState) => [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'HOURLY', label: Text('Hourly')),
            ButtonSegment(value: 'SALARY', label: Text('Salary')),
          ],
          selected: {payType},
          onSelectionChanged: (s) => setSheetState(() => payType = s.first),
        ),
        TextField(
          controller: rate,
          decoration: InputDecoration(
            labelText:
                payType == 'SALARY' ? 'Annual salary (£)' : 'Hourly rate (£)',
            prefixText: '£ ',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        _datePickerTile(
          label: 'Effective from',
          value: effectiveFrom,
          onPicked: (d) => setSheetState(() => effectiveFrom = d),
        ),
        TextField(
          controller: note,
          decoration: const InputDecoration(
              labelText: 'Note (e.g. annual review, promotion)'),
        ),
      ],
    );
    if (saved != true) return;
    if (rate.text.trim().isEmpty) {
      _snack('Enter a rate.');
      return;
    }

    await _run(
      () => _dataService.createStaffPayRate({
        'staff_member': widget.staffId,
        'pay_type': payType,
        'rate': rate.text.trim(),
        'effective_from': _iso(effectiveFrom),
        'note': note.text.trim(),
      }),
      'Failed to add pay rate',
    );
  }

  // ---------- Meetings ----------

  Widget _buildMeetingsTab() {
    final upcoming = _meetings
        .where((m) =>
            m.status == 'SCHEDULED' &&
            m.scheduledFor.isAfter(DateTime.now()))
        .toList()
      ..sort((a, b) => a.scheduledFor.compareTo(b.scheduledFor));
    final past = _meetings.where((m) => !upcoming.contains(m)).toList();

    return _listTab(
      addLabel: 'Schedule meeting',
      onAdd: _addMeeting,
      children: [
        if (_meetings.isEmpty)
          _emptyNote(
              'No meetings yet. Schedule a 1:1, team meeting or return-to-work chat.'),
        if (upcoming.isNotEmpty) _sectionHeader('Upcoming'),
        ...upcoming.map(_meetingCard),
        if (past.isNotEmpty) _sectionHeader('Past'),
        ...past.map(_meetingCard),
      ],
    );
  }

  Widget _meetingCard(StaffMeeting meeting) {
    final Color color = switch (meeting.status) {
      'COMPLETED' => AppColors.success,
      'CANCELLED' => AppColors.grey500,
      _ => AppColors.info,
    };
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withAlpha(30),
          child: Picon(PiconsDuotone.usersThree, color: color, size: 20),
        ),
        title: Text(meeting.title),
        subtitle: Text(
          '${meeting.meetingTypeLabel} · ${_formatDateTime(meeting.scheduledFor)}'
          '${meeting.location.isNotEmpty ? '\n${meeting.location}' : ''}',
        ),
        isThreeLine: meeting.location.isNotEmpty,
        trailing: Text(
          meeting.status == 'SCHEDULED'
              ? ''
              : meeting.status == 'COMPLETED'
                  ? 'Done'
                  : 'Cancelled',
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        onTap: () => _openMeeting(meeting),
      ),
    );
  }

  Future<void> _openMeeting(StaffMeeting meeting) async {
    final minutes = TextEditingController(text: meeting.minutes);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(meeting.title,
                style: Theme.of(sheetContext).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
                '${meeting.meetingTypeLabel} · ${_formatDateTime(meeting.scheduledFor)}'),
            if (meeting.attendeeNames.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('With: ${meeting.attendeeNames.join(', ')}'),
              ),
            if (meeting.agenda.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Agenda',
                  style: Theme.of(sheetContext).textTheme.titleSmall),
              Text(meeting.agenda),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: minutes,
              decoration: const InputDecoration(
                labelText: 'Minutes / notes',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
              maxLines: 5,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (meeting.status == 'SCHEDULED')
                  TextButton(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _run(
                        () => _dataService.updateStaffMeeting(
                            meeting.id, {'status': 'CANCELLED'}),
                        'Failed to cancel meeting',
                      );
                    },
                    child: const Text('Cancel meeting',
                        style: TextStyle(color: AppColors.error)),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _run(
                      () => _dataService.updateStaffMeeting(meeting.id, {
                        'minutes': minutes.text.trim(),
                        if (meeting.status == 'SCHEDULED' &&
                            minutes.text.trim().isNotEmpty)
                          'status': 'COMPLETED',
                      }),
                      'Failed to save meeting',
                    );
                  },
                  child: Text(meeting.status == 'SCHEDULED'
                      ? 'Save & complete'
                      : 'Save notes'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addMeeting() async {
    final title = TextEditingController();
    final location = TextEditingController();
    final agenda = TextEditingController();
    String meetingType = 'ONE_TO_ONE';
    DateTime scheduledFor = DateTime.now().add(const Duration(days: 1));

    final saved = await _showFormSheet(
      title: 'Schedule meeting',
      builder: (context, setSheetState) => [
        TextField(
          controller: title,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        DropdownButtonFormField<String>(
          initialValue: meetingType,
          decoration: const InputDecoration(labelText: 'Type'),
          items: const [
            DropdownMenuItem(value: 'ONE_TO_ONE', child: Text('One-to-one')),
            DropdownMenuItem(value: 'TEAM', child: Text('Team meeting')),
            DropdownMenuItem(
                value: 'RETURN_TO_WORK', child: Text('Return to work')),
            DropdownMenuItem(value: 'OTHER', child: Text('Other')),
          ],
          onChanged: (v) => setSheetState(() => meetingType = v ?? 'ONE_TO_ONE'),
        ),
        _datePickerTile(
          label: 'Date',
          value: scheduledFor,
          onPicked: (d) => setSheetState(() => scheduledFor = DateTime(
              d.year, d.month, d.day, scheduledFor.hour, scheduledFor.minute)),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Time'),
          subtitle: Text(_formatTime(scheduledFor)),
          trailing: const Picon(PiconsDuotone.clock, size: 20),
          onTap: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(scheduledFor),
            );
            if (picked != null) {
              setSheetState(() => scheduledFor = DateTime(
                  scheduledFor.year,
                  scheduledFor.month,
                  scheduledFor.day,
                  picked.hour,
                  picked.minute));
            }
          },
        ),
        TextField(
          controller: location,
          decoration: const InputDecoration(labelText: 'Location (optional)'),
        ),
        TextField(
          controller: agenda,
          decoration: const InputDecoration(
            labelText: 'Agenda (optional)',
            alignLabelWithHint: true,
          ),
          maxLines: 3,
        ),
      ],
    );
    if (saved != true) return;
    if (title.text.trim().isEmpty) {
      _snack('Enter a title.');
      return;
    }

    await _run(
      () => _dataService.createStaffMeeting({
        'title': title.text.trim(),
        'meeting_type': meetingType,
        'scheduled_for': scheduledFor.toIso8601String(),
        'location': location.text.trim(),
        'agenda': agenda.text.trim(),
        'attendees': [widget.staffId],
      }),
      'Failed to schedule meeting',
    );
  }

  // ---------- Appraisals ----------

  Widget _buildAppraisalsTab() {
    return _listTab(
      addLabel: 'New appraisal',
      onAdd: _addAppraisal,
      children: [
        if (_appraisals.isEmpty)
          _emptyNote(
              'No appraisals yet. Draft one, then share it with ${widget.staffName} when it\'s ready.'),
        ..._appraisals.map(_appraisalCard),
      ],
    );
  }

  Widget _appraisalCard(StaffAppraisal appraisal) {
    final Color color = switch (appraisal.status) {
      'ACKNOWLEDGED' => AppColors.success,
      'SHARED' => AppColors.info,
      _ => AppColors.warning,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Picon(PiconsDuotone.star, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Appraisal · ${_formatDate(appraisal.appraisalDate)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withAlpha(26),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    appraisal.statusLabel,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (appraisal.overallRating != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: List.generate(
                    5,
                    (i) => Picon(
                      PiconsDuotone.star,
                      size: 16,
                      color: i < appraisal.overallRating!
                          ? AppColors.warning
                          : AppColors.grey400,
                    ),
                  ),
                ),
              ),
            if (appraisal.summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(appraisal.summary,
                    maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
            if (appraisal.staffComments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${widget.staffName}: "${appraisal.staffComments}"',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _viewAppraisal(appraisal),
                  child: const Text('View'),
                ),
                if (appraisal.status == 'DRAFT') ...[
                  TextButton(
                    onPressed: () => _editAppraisal(appraisal),
                    child: const Text('Edit'),
                  ),
                  FilledButton(
                    onPressed: () => _run(
                      () => _dataService.shareStaffAppraisal(appraisal.id),
                      'Failed to share appraisal',
                    ),
                    child: Text('Share with ${widget.staffName}'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _viewAppraisal(StaffAppraisal appraisal) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('Appraisal · ${_formatDate(appraisal.appraisalDate)}',
                style: Theme.of(context).textTheme.titleLarge),
            if (appraisal.appraiserName != null)
              Text('By ${appraisal.appraiserName}'),
            for (final (label, text) in [
              ('Summary', appraisal.summary),
              ('Strengths', appraisal.strengths),
              ('Areas for improvement', appraisal.areasForImprovement),
              ('Goals', appraisal.goals),
              ('${widget.staffName}\'s comments', appraisal.staffComments),
            ])
              if (text.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(label, style: Theme.of(context).textTheme.titleSmall),
                Text(text),
              ],
            if (appraisal.nextReviewDate != null) ...[
              const SizedBox(height: 12),
              Text('Next review: ${_formatDate(appraisal.nextReviewDate!)}'),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _addAppraisal() => _appraisalForm();

  Future<void> _editAppraisal(StaffAppraisal appraisal) =>
      _appraisalForm(existing: appraisal);

  Future<void> _appraisalForm({StaffAppraisal? existing}) async {
    final summary = TextEditingController(text: existing?.summary ?? '');
    final strengths = TextEditingController(text: existing?.strengths ?? '');
    final areas =
        TextEditingController(text: existing?.areasForImprovement ?? '');
    final goals = TextEditingController(text: existing?.goals ?? '');
    DateTime appraisalDate = existing?.appraisalDate ?? DateTime.now();
    DateTime? nextReview = existing?.nextReviewDate;
    int? rating = existing?.overallRating;

    final saved = await _showFormSheet(
      title: existing == null ? 'New appraisal (draft)' : 'Edit appraisal',
      builder: (context, setSheetState) => [
        _datePickerTile(
          label: 'Appraisal date',
          value: appraisalDate,
          onPicked: (d) => setSheetState(() => appraisalDate = d),
        ),
        Row(
          children: [
            const Text('Overall rating:'),
            const SizedBox(width: 8),
            ...List.generate(
              5,
              (i) => IconButton(
                visualDensity: VisualDensity.compact,
                icon: Picon(
                  PiconsDuotone.star,
                  color: (rating ?? 0) > i
                      ? AppColors.warning
                      : AppColors.grey400,
                ),
                onPressed: () => setSheetState(() => rating = i + 1),
              ),
            ),
          ],
        ),
        TextField(
          controller: summary,
          decoration: const InputDecoration(
              labelText: 'Summary', alignLabelWithHint: true),
          maxLines: 3,
        ),
        TextField(
          controller: strengths,
          decoration: const InputDecoration(
              labelText: 'Strengths', alignLabelWithHint: true),
          maxLines: 3,
        ),
        TextField(
          controller: areas,
          decoration: const InputDecoration(
              labelText: 'Areas for improvement', alignLabelWithHint: true),
          maxLines: 3,
        ),
        TextField(
          controller: goals,
          decoration: const InputDecoration(
              labelText: 'Goals for next period', alignLabelWithHint: true),
          maxLines: 3,
        ),
        _datePickerTile(
          label: 'Next review due',
          value: nextReview,
          onPicked: (d) => setSheetState(() => nextReview = d),
          allowClear: true,
          onCleared: () => setSheetState(() => nextReview = null),
        ),
      ],
    );
    if (saved != true) return;

    final fields = {
      'appraisal_date': _iso(appraisalDate),
      'overall_rating': rating,
      'summary': summary.text.trim(),
      'strengths': strengths.text.trim(),
      'areas_for_improvement': areas.text.trim(),
      'goals': goals.text.trim(),
      'next_review_date': _isoOrNull(nextReview),
    };
    await _run(
      () => existing == null
          ? _dataService
              .createStaffAppraisal({...fields, 'staff_member': widget.staffId})
          : _dataService.updateStaffAppraisal(existing.id, fields),
      'Failed to save appraisal',
    );
  }

  // ---------- Records (sickness + training) ----------

  Widget _buildRecordsTab() {
    return RefreshIndicator.adaptive(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              _sectionHeader('Sickness'),
              const Spacer(),
              TextButton.icon(
                onPressed: _addAbsence,
                icon: const Picon(PiconsDuotone.plusCircle, size: 18),
                label: const Text('Record'),
              ),
            ],
          ),
          if (_absences.isEmpty) _emptyNote('No sickness recorded.'),
          ..._absences.map(
            (absence) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: (absence.ongoing
                          ? AppColors.error
                          : AppColors.grey500)
                      .withAlpha(30),
                  child: Picon(
                    PiconsDuotone.heartbeat,
                    color:
                        absence.ongoing ? AppColors.error : AppColors.grey500,
                    size: 20,
                  ),
                ),
                title: Text(
                  absence.ongoing
                      ? 'Off since ${_formatDate(absence.startDate)}'
                      : '${_formatDate(absence.startDate)} – ${_formatDate(absence.endDate!)}',
                ),
                subtitle:
                    absence.reason.isNotEmpty ? Text(absence.reason) : null,
                trailing: absence.ongoing
                    ? TextButton(
                        onPressed: () => _endAbsence(absence),
                        child: const Text('Back at work'),
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _sectionHeader('Training & qualifications'),
              const Spacer(),
              TextButton.icon(
                onPressed: _addTraining,
                icon: const Picon(PiconsDuotone.plusCircle, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          if (_training.isEmpty)
            _emptyNote('Nothing recorded — e.g. Canine First Aid.'),
          ..._training.map(
            (record) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      _trainingColor(record.expiryStatus).withAlpha(30),
                  child: Picon(
                    PiconsDuotone.graduationCap,
                    color: _trainingColor(record.expiryStatus),
                    size: 20,
                  ),
                ),
                title: Text(record.name),
                subtitle: Text([
                  if (record.provider.isNotEmpty) record.provider,
                  if (record.completedDate != null)
                    'Completed ${_formatDate(record.completedDate!)}',
                  if (record.expiryDate != null)
                    record.expiryStatus == 'EXPIRED'
                        ? 'EXPIRED ${_formatDate(record.expiryDate!)}'
                        : 'Expires ${_formatDate(record.expiryDate!)}',
                ].join(' · ')),
                trailing: IconButton(
                  icon: const Picon(PiconsDuotone.trash, size: 20),
                  onPressed: () => _confirmDelete(
                    'Delete "${record.name}"?',
                    () => _dataService.deleteStaffTrainingRecord(record.id),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _trainingColor(String status) => switch (status) {
        'EXPIRED' => AppColors.error,
        'EXPIRING' => AppColors.warning,
        _ => AppColors.success,
      };

  Future<void> _addAbsence() async {
    final reason = TextEditingController();
    final notes = TextEditingController();
    DateTime startDate = DateTime.now();
    DateTime? endDate;

    final saved = await _showFormSheet(
      title: 'Record sickness absence',
      builder: (context, setSheetState) => [
        _datePickerTile(
          label: 'First day off',
          value: startDate,
          onPicked: (d) => setSheetState(() => startDate = d),
        ),
        _datePickerTile(
          label: 'Last day off (leave blank if still off)',
          value: endDate,
          onPicked: (d) => setSheetState(() => endDate = d),
          allowClear: true,
          onCleared: () => setSheetState(() => endDate = null),
        ),
        TextField(
          controller: reason,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        TextField(
          controller: notes,
          decoration: const InputDecoration(
            labelText: 'Notes (fit note, return-to-work…)',
            alignLabelWithHint: true,
          ),
          maxLines: 3,
        ),
      ],
    );
    if (saved != true) return;

    await _run(
      () => _dataService.createSicknessAbsence({
        'staff_member': widget.staffId,
        'start_date': _iso(startDate),
        'end_date': _isoOrNull(endDate),
        'reason': reason.text.trim(),
        'notes': notes.text.trim(),
      }),
      'Failed to record absence',
    );
  }

  Future<void> _endAbsence(SicknessAbsence absence) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: absence.startDate,
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'Last day off sick',
    );
    if (picked == null) return;
    await _run(
      () => _dataService
          .updateSicknessAbsence(absence.id, {'end_date': _iso(picked)}),
      'Failed to update absence',
    );
  }

  Future<void> _addTraining() async {
    final name = TextEditingController();
    final provider = TextEditingController();
    final notes = TextEditingController();
    DateTime? completed = DateTime.now();
    DateTime? expiry;

    final saved = await _showFormSheet(
      title: 'Add training / qualification',
      builder: (context, setSheetState) => [
        TextField(
          controller: name,
          decoration:
              const InputDecoration(labelText: 'Name (e.g. Canine First Aid)'),
        ),
        TextField(
          controller: provider,
          decoration: const InputDecoration(labelText: 'Provider (optional)'),
        ),
        _datePickerTile(
          label: 'Completed',
          value: completed,
          onPicked: (d) => setSheetState(() => completed = d),
          allowClear: true,
          onCleared: () => setSheetState(() => completed = null),
        ),
        _datePickerTile(
          label: 'Expires (blank if it doesn\'t)',
          value: expiry,
          onPicked: (d) => setSheetState(() => expiry = d),
          allowClear: true,
          onCleared: () => setSheetState(() => expiry = null),
        ),
        TextField(
          controller: notes,
          decoration: const InputDecoration(labelText: 'Notes'),
        ),
      ],
    );
    if (saved != true) return;
    if (name.text.trim().isEmpty) {
      _snack('Enter a name.');
      return;
    }

    await _run(
      () => _dataService.createStaffTrainingRecord({
        'staff_member': widget.staffId,
        'name': name.text.trim(),
        'provider': provider.text.trim(),
        'completed_date': _isoOrNull(completed),
        'expiry_date': _isoOrNull(expiry),
        'notes': notes.text.trim(),
      }),
      'Failed to add training record',
    );
  }

  // ---------- shared building blocks ----------

  /// A tab that is a refreshable list with a bottom "add" button.
  Widget _listTab({
    required String addLabel,
    required Future<void> Function() onAdd,
    required List<Widget> children,
  }) {
    return RefreshIndicator.adaptive(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          ...children,
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Picon(PiconsDuotone.plusCircle, size: 20),
            label: Text(addLabel),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required dynamic icon,
    VoidCallback? onEdit,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Picon(icon, size: 20, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (onEdit != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Picon(PiconsDuotone.notePencil, size: 18),
                    onPressed: onEdit,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
      );

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: Text(
                label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  Widget _emptyNote(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          text,
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );

  Widget _datePickerTile({
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime> onPicked,
    bool allowClear = false,
    VoidCallback? onCleared,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(value != null ? _formatDate(value) : 'Not set'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (allowClear && value != null)
            IconButton(
              icon: const Picon(PiconsDuotone.xCircle, size: 20),
              onPressed: onCleared,
            ),
          const Picon(PiconsDuotone.calendarCheck, size: 20),
        ],
      ),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onPicked(picked);
      },
    );
  }

  /// Modal bottom-sheet form. Resolves true when "Save" is tapped.
  Future<bool?> _showFormSheet({
    required String title,
    required List<Widget> Function(
            BuildContext context, StateSetter setSheetState)
        builder,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                ...builder(context, setSheetState)
                    .expand((w) => [w, const SizedBox(height: 10)]),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetContext, true),
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
      String message, Future<void> Function() action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(action, 'Failed to delete');
    }
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String? _isoOrNull(DateTime? d) => d != null ? _iso(d) : null;

  String _formatDate(DateTime d) => '${d.day}/${d.month}/${d.year}';

  String _formatTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _formatDateTime(DateTime d) => '${_formatDate(d)} ${_formatTime(d)}';

  String _trimZero(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
