import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/compliance.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/page_body.dart';

/// The Safety & Compliance register: recurring facility checks (fire alarm
/// tests, extinguisher servicing, first aid kits, licence and insurance
/// renewals…) grouped by category, each with its last-done and next-due
/// dates. Any staff member can record a completed check; adding or editing
/// the checks themselves needs the Manage Compliance permission.
class ComplianceScreen extends StatefulWidget {
  final bool canManage;

  const ComplianceScreen({super.key, this.canManage = false});

  @override
  State<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends State<ComplianceScreen> {
  final DataService _dataService = getIt<DataService>();

  List<ComplianceCheck> _checks = [];
  bool _loading = true;
  bool _showInactive = false;
  String? _error;

  static const _categoryOrder = [
    'FIRE',
    'ELECTRICAL',
    'HEALTH_SAFETY',
    'HYGIENE',
    'DOCUMENTS',
    'OTHER',
  ];

  // Sort key: things needing attention float to the top of their category.
  static const _statusRank = {
    'OVERDUE': 0,
    'NEVER_DONE': 1,
    'DUE_SOON': 2,
    'OK': 3,
    'NONE': 4,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final checks =
          await _dataService.getComplianceChecks(includeInactive: _showInactive);
      if (!mounted) return;
      setState(() {
        _checks = checks;
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
    final needsAttention = _checks
        .where((c) =>
            c.status == 'OVERDUE' ||
            c.status == 'NEVER_DONE' ||
            c.status == 'DUE_SOON')
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety & Compliance'),
        actions: [
          if (widget.canManage)
            IconButton(
              tooltip: _showInactive
                  ? 'Hide retired checks'
                  : 'Show retired checks',
              icon: Picon(_showInactive
                  ? PiconsDuotone.eyeSlash
                  : PiconsDuotone.eye),
              onPressed: () {
                setState(() {
                  _showInactive = !_showInactive;
                  _loading = true;
                });
                _load();
              },
            ),
        ],
      ),
      floatingActionButton: widget.canManage
          ? FloatingActionButton.extended(
              onPressed: () => _checkForm(),
              icon: const Picon(PiconsDuotone.plusCircle),
              label: const Text('Add check'),
            )
          : null,
      body: PageBody(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : RefreshIndicator.adaptive(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                    children: [
                      if (needsAttention > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '$needsAttention check${needsAttention == 1 ? '' : 's'} need${needsAttention == 1 ? 's' : ''} attention',
                            style: const TextStyle(
                              color: AppColors.warning,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ..._buildGroupedList(),
                    ],
                  ),
                )),
    );
  }

  Widget _buildError() {
    return Center(
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
    );
  }

  List<Widget> _buildGroupedList() {
    final widgets = <Widget>[];
    for (final category in _categoryOrder) {
      final inCategory = _checks.where((c) => c.category == category).toList()
        ..sort((a, b) {
          final rank = (_statusRank[a.status] ?? 5)
              .compareTo(_statusRank[b.status] ?? 5);
          return rank != 0 ? rank : a.name.compareTo(b.name);
        });
      if (inCategory.isEmpty) continue;
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          inCategory.first.categoryLabel,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ));
      widgets.addAll(inCategory.map(_buildCheckCard));
    }
    return widgets;
  }

  (Color, String) _statusPresentation(ComplianceCheck check) {
    switch (check.status) {
      case 'OVERDUE':
        return (AppColors.error, 'Overdue');
      case 'NEVER_DONE':
        return (AppColors.error, 'Never done');
      case 'DUE_SOON':
        return (AppColors.warning, 'Due soon');
      case 'OK':
        return (AppColors.success, 'OK');
      default:
        return (AppColors.grey500, check.isActive ? 'No schedule' : 'Retired');
    }
  }

  Widget _buildCheckCard(ComplianceCheck check) {
    final (color, label) = _statusPresentation(check);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withAlpha(30),
          child: Picon(PiconsDuotone.shieldCheck, color: color, size: 20),
        ),
        title: Text(check.name),
        subtitle: Text(
          '${check.frequencyLabel}'
          '${check.lastDone != null ? ' · last ${_formatDate(check.lastDone!)}' : ''}'
          '${check.nextDue != null ? ' · due ${_formatDate(check.nextDue!)}' : ''}',
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        onTap: () => _openCheck(check),
      ),
    );
  }

  Future<void> _openCheck(ComplianceCheck check) async {
    List<ComplianceLog>? history;
    try {
      history = await _dataService.getComplianceLogs(check.id);
    } catch (_) {
      history = null; // shown as a load failure inside the sheet
    }
    if (!mounted) return;

    final (color, label) = _statusPresentation(check);
    await showModalBottomSheet<void>(
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
            Row(
              children: [
                Expanded(
                  child: Text(check.name,
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                if (widget.canManage)
                  IconButton(
                    icon: const Picon(PiconsDuotone.notePencil, size: 20),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _checkForm(existing: check);
                    },
                  ),
              ],
            ),
            Text('${check.categoryLabel} · ${check.frequencyLabel} · $label',
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            if (check.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(check.description),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(sheetContext);
                _logCheck(check);
              },
              icon: const Picon(PiconsDuotone.checkCircle, size: 20),
              label: const Text('Record this check'),
            ),
            const SizedBox(height: 16),
            Text('History', style: Theme.of(context).textTheme.titleSmall),
            if (history == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Could not load history.'),
              )
            else if (history.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Never recorded.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              )
            else
              ...history.map(
                (log) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Picon(
                    log.result == 'PASS'
                        ? PiconsDuotone.checkCircle
                        : PiconsDuotone.warning,
                    color: log.result == 'PASS'
                        ? AppColors.success
                        : AppColors.warning,
                    size: 22,
                  ),
                  title: Text(_formatDate(log.performedOn) +
                      (log.performedByName != null
                          ? ' — ${log.performedByName}'
                          : '')),
                  subtitle: log.notes.isNotEmpty ? Text(log.notes) : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _logCheck(ComplianceCheck check) async {
    final notes = TextEditingController();
    String result = 'PASS';
    DateTime performedOn = DateTime.now();

    final saved = await showModalBottomSheet<bool>(
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Record: ${check.name}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date'),
                subtitle: Text(_formatDate(performedOn)),
                trailing: const Picon(PiconsDuotone.calendarCheck, size: 20),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: performedOn,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setSheetState(() => performedOn = picked);
                  }
                },
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'PASS', label: Text('All OK')),
                  ButtonSegment(value: 'ISSUES', label: Text('Issues found')),
                ],
                selected: {result},
                onSelectionChanged: (s) =>
                    setSheetState(() => result = s.first),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (e.g. call point tested, items replaced)',
                  alignLabelWithHint: true,
                ),
                maxLines: 3,
              ),
              if (result == 'ISSUES')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Anything that needs fixing should also be reported as a '
                    'facility defect so it gets tracked to resolution.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(sheetContext, true),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;

    await _run(
      () => _dataService.logComplianceCheck({
        'check_type': check.id,
        'performed_on': _iso(performedOn),
        'result': result,
        'notes': notes.text.trim(),
      }),
      'Failed to record check',
    );
  }

  Future<void> _checkForm({ComplianceCheck? existing}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final description = TextEditingController(text: existing?.description ?? '');
    String category = existing?.category ?? 'FIRE';
    String frequency = existing?.frequency ?? 'MONTHLY';
    bool isActive = existing?.isActive ?? true;

    final saved = await showModalBottomSheet<bool>(
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
                Text(existing == null ? 'Add check' : 'Edit check',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: const [
                    DropdownMenuItem(value: 'FIRE', child: Text('Fire safety')),
                    DropdownMenuItem(
                        value: 'ELECTRICAL', child: Text('Electrical')),
                    DropdownMenuItem(
                        value: 'HEALTH_SAFETY', child: Text('Health & safety')),
                    DropdownMenuItem(
                        value: 'HYGIENE', child: Text('Hygiene & pest control')),
                    DropdownMenuItem(
                        value: 'DOCUMENTS',
                        child: Text('Licences, insurance & documents')),
                    DropdownMenuItem(value: 'OTHER', child: Text('Other')),
                  ],
                  onChanged: (v) => setSheetState(() => category = v ?? 'OTHER'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: frequency,
                  decoration: const InputDecoration(labelText: 'How often'),
                  items: const [
                    DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
                    DropdownMenuItem(value: 'MONTHLY', child: Text('Monthly')),
                    DropdownMenuItem(
                        value: 'QUARTERLY', child: Text('Quarterly')),
                    DropdownMenuItem(
                        value: 'SIX_MONTHLY', child: Text('Every 6 months')),
                    DropdownMenuItem(value: 'ANNUAL', child: Text('Yearly')),
                    DropdownMenuItem(
                        value: 'TWO_YEARLY', child: Text('Every 2 years')),
                    DropdownMenuItem(
                        value: 'FIVE_YEARLY', child: Text('Every 5 years')),
                    DropdownMenuItem(
                        value: 'AD_HOC', child: Text('As needed (no schedule)')),
                  ],
                  onChanged: (v) =>
                      setSheetState(() => frequency = v ?? 'MONTHLY'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(
                    labelText: 'What the check involves (optional)',
                    alignLabelWithHint: true,
                  ),
                  maxLines: 3,
                ),
                if (existing != null)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    subtitle: const Text(
                        'Retired checks keep their history but stop being due.'),
                    value: isActive,
                    onChanged: (v) => setSheetState(() => isActive = v),
                  ),
                const SizedBox(height: 12),
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
    if (saved != true) return;
    if (name.text.trim().isEmpty) {
      _snack('Enter a name.');
      return;
    }

    final fields = {
      'name': name.text.trim(),
      'category': category,
      'frequency': frequency,
      'description': description.text.trim(),
      'is_active': isActive,
    };
    await _run(
      () => existing == null
          ? _dataService.createComplianceCheck(fields)
          : _dataService.updateComplianceCheck(existing.id, fields),
      'Failed to save check',
    );
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _formatDate(DateTime d) => '${d.day}/${d.month}/${d.year}';
}
