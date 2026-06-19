import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/vaccination_record.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/app_sheets.dart';
import '../widgets/grouped_section.dart';

/// Vaccination records for a dog. Staff can add, edit and delete records;
/// owners get a read-only view. Expiry reminders are sent automatically.
class VaccinationsScreen extends StatefulWidget {
  final Dog dog;
  final bool isStaff;

  const VaccinationsScreen({super.key, required this.dog, required this.isStaff});

  @override
  State<VaccinationsScreen> createState() => _VaccinationsScreenState();
}

class _VaccinationsScreenState extends State<VaccinationsScreen> {
  final DataService _dataService = getIt<DataService>();
  late Future<List<VaccinationRecord>> _recordsFuture;

  static const _commonVaccines = ['DHP', 'Leptospirosis', 'Kennel Cough', 'Rabies'];

  @override
  void initState() {
    super.initState();
    _recordsFuture = _dataService.getVaccinations(widget.dog.id);
  }

  Future<void> _refresh() async {
    setState(() {
      _recordsFuture = _dataService.getVaccinations(widget.dog.id);
    });
    await _recordsFuture;
  }

  Color _statusColor(VaccinationRecord record) {
    if (record.isExpired) return AppColors.error;
    if (record.isExpiringSoon) return AppColors.warning;
    return AppColors.success;
  }

  String _statusLabel(VaccinationRecord record) {
    if (record.isExpired) return 'Expired';
    if (record.isExpiringSoon) return 'Expires soon';
    return 'Up to date';
  }

  Widget _statusChip(VaccinationRecord record) {
    final color = _statusColor(record);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _statusLabel(record),
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _showRecordSheet({VaccinationRecord? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final notesController = TextEditingController(text: existing?.notes ?? '');
    DateTime administered = existing?.dateAdministered ?? DateTime.now();
    DateTime expiry = existing?.expiryDate ??
        DateTime.now().add(const Duration(days: 365));
    bool saving = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> pickDate({required bool isExpiry}) async {
            final initial = isExpiry ? expiry : administered;
            final picked = await showDatePicker(
              context: sheetContext,
              initialDate: initial,
              firstDate: DateTime.now().subtract(const Duration(days: 365 * 5)),
              lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
            );
            if (picked != null) {
              setSheetState(() {
                if (isExpiry) {
                  expiry = picked;
                } else {
                  administered = picked;
                }
              });
            }
          }

          Future<void> save() async {
            final name = nameController.text.trim();
            if (name.isEmpty) return;
            final messenger = ScaffoldMessenger.of(context);
            setSheetState(() => saving = true);
            try {
              if (existing == null) {
                await _dataService.createVaccination(
                  dogId: widget.dog.id,
                  name: name,
                  dateAdministered: administered,
                  expiryDate: expiry,
                  notes: notesController.text.trim().isEmpty
                      ? null
                      : notesController.text.trim(),
                );
              } else {
                await _dataService.updateVaccination(
                  existing.id,
                  name: name,
                  dateAdministered: administered,
                  expiryDate: expiry,
                  notes: notesController.text.trim(),
                );
              }
              if (sheetContext.mounted) Navigator.pop(sheetContext);
              _refresh();
            } catch (e) {
              if (sheetContext.mounted) {
                setSheetState(() => saving = false);
              }
              messenger.showSnackBar(
                SnackBar(
                  content: Text('Could not save record: $e'),
                  backgroundColor: AppColors.error,
                ),
              );
            }
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              16, 8, 16, MediaQuery.of(sheetContext).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  existing == null ? 'Add Vaccination' : 'Edit Vaccination',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Vaccine name'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final vaccine in _commonVaccines)
                      ActionChip(
                        label: Text(vaccine),
                        onPressed: () =>
                            setSheetState(() => nameController.text = vaccine),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Picon(PiconsDuotone.syringe),
                  title: const Text('Date administered'),
                  trailing: Text(ukDate(administered)),
                  onTap: saving ? null : () => pickDate(isExpiry: false),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Picon(PiconsDuotone.calendarX),
                  title: const Text('Expiry date'),
                  trailing: Text(ukDate(expiry)),
                  onTap: saving ? null : () => pickDate(isExpiry: true),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'e.g. Booster due, given at Vets4Pets',
                  ),
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: saving ? null : save,
                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(existing == null ? 'Add Record' : 'Save Changes'),
                ),
              ],
            ),
          );
        },
      ),
    );

    nameController.dispose();
    notesController.dispose();
  }

  Future<void> _showRecordOptions(VaccinationRecord record) async {
    final choice = await showAppActionSheet<String>(
      context,
      title: '${record.name} — ${widget.dog.name}',
      actions: [
        const AppSheetAction(label: 'Edit', value: 'edit'),
        const AppSheetAction(label: 'Delete', value: 'delete', isDestructive: true),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'edit') {
      _showRecordSheet(existing: record);
    } else if (choice == 'delete') {
      try {
        await _dataService.deleteVaccination(record.id);
        _refresh();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not delete record: $e'),
              backgroundColor: AppColors.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.dog.name} — Vaccinations')),
      floatingActionButton: widget.isStaff
          ? FloatingActionButton.extended(
              onPressed: () => _showRecordSheet(),
              icon: const Picon(PiconsDuotone.plus),
              label: const Text('Add Record'),
            )
          : null,
      body: FutureBuilder<List<VaccinationRecord>>(
        future: _recordsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final records = snapshot.data ?? [];
          return RefreshIndicator.adaptive(
            onRefresh: _refresh,
            child: records.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.55,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Picon(PiconsDuotone.syringe,
                                  size: 56, color: AppColors.iosSecondaryLabel),
                              const SizedBox(height: 12),
                              Text(
                                'No vaccination records yet',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 6),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 40),
                                child: Text(
                                  widget.isStaff
                                      ? 'Add the first record with the button below.'
                                      : 'Staff will add records when you show your vaccination card.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      GroupedSection(
                        header: 'Records',
                        footer: widget.isStaff
                            ? 'Owners are reminded automatically 30 days and 7 days before expiry.'
                            : 'Records are maintained by staff — contact us to update them. We\'ll remind you before anything expires.',
                        children: [
                          for (final record in records)
                            ListTile(
                              leading: Picon(
                                PiconsDuotone.syringe,
                                color: _statusColor(record),
                              ),
                              title: Text(record.name),
                              subtitle: Text(
                                'Given ${ukDate(record.dateAdministered)} · Expires ${ukDate(record.expiryDate)}'
                                '${(record.notes?.isNotEmpty ?? false) ? '\n${record.notes}' : ''}',
                              ),
                              isThreeLine: record.notes?.isNotEmpty ?? false,
                              trailing: _statusChip(record),
                              onTap: widget.isStaff
                                  ? () => _showRecordOptions(record)
                                  : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 80),
                    ],
                  ),
          );
        },
      ),
    );
  }
}
