import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/app_colors.dart';
import '../models/closure_day.dart';
import '../services/data_service.dart';

class ClosureDaysScreen extends StatefulWidget {
  final bool isStaff;
  const ClosureDaysScreen({super.key, required this.isStaff});

  @override
  State<ClosureDaysScreen> createState() => _ClosureDaysScreenState();
}

class _ClosureDaysScreenState extends State<ClosureDaysScreen> {
  final DataService _dataService = ApiDataService();
  List<ClosureDay> _closureDays = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final days = await _dataService.getClosureDays(
        fromDate: DateTime.now(),
      );
      if (mounted) setState(() { _closureDays = days; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load closure days: $e')),
        );
      }
    }
  }

  Future<void> _addClosureDay() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _AddClosureDayDialog(),
    );
    if (result == null) return;

    try {
      await _dataService.createClosureDay(
        date: result['date'],
        closureType: result['closure_type'],
        reason: result['reason'] ?? '',
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create closure day: $e')),
        );
      }
    }
  }

  Future<void> _deleteClosureDay(ClosureDay day) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Closure'),
        content: Text('Remove the closure on ${DateFormat('EEE, d MMM yyyy').format(day.date)}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _dataService.deleteClosureDay(day.id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove closure day: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Holiday & Closures')),
      floatingActionButton: widget.isStaff
          ? FloatingActionButton.extended(
              onPressed: _addClosureDay,
              icon: const Icon(Icons.add),
              label: const Text('Add Closure'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _closureDays.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.event_available, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('No upcoming closures', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _closureDays.length,
                    itemBuilder: (context, index) {
                      final day = _closureDays[index];
                      final isClosed = day.closureType == ClosureType.closed;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isClosed ? AppColors.error.withAlpha(30) : AppColors.warning.withAlpha(30),
                            child: Icon(
                              isClosed ? Icons.block : Icons.warning_amber,
                              color: isClosed ? AppColors.error : AppColors.warning,
                            ),
                          ),
                          title: Text(
                            DateFormat('EEEE, d MMMM yyyy').format(day.date),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isClosed ? AppColors.error : AppColors.warning,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  day.closureType.displayName,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                              if (day.reason.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(day.reason),
                              ],
                            ],
                          ),
                          trailing: widget.isStaff
                              ? IconButton(
                                  icon: const Icon(Icons.delete_outline, color: AppColors.error),
                                  onPressed: () => _deleteClosureDay(day),
                                )
                              : null,
                          isThreeLine: day.reason.isNotEmpty,
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _AddClosureDayDialog extends StatefulWidget {
  const _AddClosureDayDialog();

  @override
  State<_AddClosureDayDialog> createState() => _AddClosureDayDialogState();
}

class _AddClosureDayDialogState extends State<_AddClosureDayDialog> {
  DateTime? _selectedDate;
  ClosureType _closureType = ClosureType.closed;
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Closure Day'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today),
              title: Text(
                _selectedDate == null
                    ? 'Select date'
                    : DateFormat('EEE, d MMM yyyy').format(_selectedDate!),
              ),
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now().add(const Duration(days: 1)),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (date != null) setState(() => _selectedDate = date);
              },
            ),
            const SizedBox(height: 8),
            const Text('Type', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SegmentedButton<ClosureType>(
              segments: const [
                ButtonSegment(value: ClosureType.closed, label: Text('Closed'), icon: Icon(Icons.block)),
                ButtonSegment(value: ClosureType.reduced, label: Text('Reduced'), icon: Icon(Icons.warning_amber)),
              ],
              selected: {_closureType},
              onSelectionChanged: (set) => setState(() => _closureType = set.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _reasonController,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. Bank Holiday, Christmas',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _selectedDate == null
              ? null
              : () {
                  Navigator.pop(context, {
                    'date': _selectedDate,
                    'closure_type': _closureType,
                    'reason': _reasonController.text.trim(),
                  });
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
