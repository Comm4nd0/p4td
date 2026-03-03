import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../models/staff_availability.dart';
import '../services/data_service.dart';

class StaffAvailabilityScreen extends StatefulWidget {
  final bool canAssignDogs;
  const StaffAvailabilityScreen({super.key, required this.canAssignDogs});

  @override
  State<StaffAvailabilityScreen> createState() => _StaffAvailabilityScreenState();
}

class _StaffAvailabilityScreenState extends State<StaffAvailabilityScreen> with SingleTickerProviderStateMixin {
  final DataService _dataService = ApiDataService();
  late TabController _tabController;

  // My Availability tab
  Map<int, bool> _myAvailability = {};
  Map<int, String> _myNotes = {};
  bool _loadingMy = true;
  bool _saving = false;

  // Coverage tab
  Map<String, dynamic> _coverage = {};
  bool _loadingCoverage = true;

  static const _dayNames = {
    1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday',
    5: 'Friday', 6: 'Saturday', 7: 'Sunday',
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: widget.canAssignDogs ? 2 : 1, vsync: this);
    _loadMyAvailability();
    if (widget.canAssignDogs) _loadCoverage();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadMyAvailability() async {
    setState(() => _loadingMy = true);
    try {
      final avail = await _dataService.getMyAvailability();
      final map = <int, bool>{};
      final notes = <int, String>{};
      for (final a in avail) {
        map[a.dayOfWeek] = a.isAvailable;
        notes[a.dayOfWeek] = a.note;
      }
      // Default to available for days not set
      for (int i = 1; i <= 7; i++) {
        map.putIfAbsent(i, () => true);
        notes.putIfAbsent(i, () => '');
      }
      if (mounted) setState(() { _myAvailability = map; _myNotes = notes; _loadingMy = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingMy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load availability: $e')),
        );
      }
    }
  }

  Future<void> _loadCoverage() async {
    setState(() => _loadingCoverage = true);
    try {
      final coverage = await _dataService.getStaffCoverage();
      if (mounted) setState(() { _coverage = coverage; _loadingCoverage = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingCoverage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load coverage: $e')),
        );
      }
    }
  }

  Future<void> _saveMyAvailability() async {
    setState(() => _saving = true);
    try {
      final data = <Map<String, dynamic>>[];
      for (int i = 1; i <= 7; i++) {
        data.add({
          'day_of_week': i,
          'is_available': _myAvailability[i] ?? true,
          'note': _myNotes[i] ?? '',
        });
      }
      await _dataService.setMyAvailability(data);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Availability saved'), backgroundColor: AppColors.success),
        );
      }
      if (widget.canAssignDogs) _loadCoverage();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Availability'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            const Tab(text: 'My Availability'),
            if (widget.canAssignDogs) const Tab(text: 'Team Coverage'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMyAvailabilityTab(),
          if (widget.canAssignDogs) _buildCoverageTab(),
        ],
      ),
    );
  }

  Widget _buildMyAvailabilityTab() {
    if (_loadingMy) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: 7,
            itemBuilder: (context, index) {
              final day = index + 1;
              final isAvailable = _myAvailability[day] ?? true;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isAvailable
                        ? AppColors.success.withAlpha(30)
                        : AppColors.error.withAlpha(30),
                    child: Icon(
                      isAvailable ? Icons.check : Icons.close,
                      color: isAvailable ? AppColors.success : AppColors.error,
                    ),
                  ),
                  title: Text(
                    _dayNames[day]!,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: _myNotes[day]?.isNotEmpty == true
                      ? Text(_myNotes[day]!)
                      : null,
                  trailing: Switch(
                    value: isAvailable,
                    onChanged: (val) {
                      setState(() => _myAvailability[day] = val);
                    },
                    activeColor: AppColors.success,
                  ),
                  onTap: () async {
                    final controller = TextEditingController(text: _myNotes[day]);
                    final note = await showDialog<String>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('${_dayNames[day]} Note'),
                        content: TextField(
                          controller: controller,
                          decoration: const InputDecoration(
                            hintText: 'e.g. Available mornings only',
                            border: OutlineInputBorder(),
                          ),
                          textCapitalization: TextCapitalization.sentences,
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
                        ],
                      ),
                    );
                    if (note != null) {
                      setState(() => _myNotes[day] = note.trim());
                    }
                  },
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _saveMyAvailability,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save),
              label: const Text('Save Availability'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCoverageTab() {
    if (_loadingCoverage) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _loadCoverage,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 7,
        itemBuilder: (context, index) {
          final dayKey = '${index + 1}';
          final dayData = _coverage[dayKey] as Map<String, dynamic>?;
          if (dayData == null) return const SizedBox.shrink();

          final dayName = dayData['day_name'] as String? ?? _dayNames[index + 1]!;
          final available = (dayData['available'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final unavailable = (dayData['unavailable'] as List?)?.cast<Map<String, dynamic>>() ?? [];

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(dayName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: available.isEmpty ? AppColors.error.withAlpha(30) : AppColors.success.withAlpha(30),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${available.length} available',
                          style: TextStyle(
                            fontSize: 12,
                            color: available.isEmpty ? AppColors.error : AppColors.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (available.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: available.map((s) => Chip(
                        avatar: const Icon(Icons.check_circle, size: 16, color: AppColors.success),
                        label: Text(s['name'] as String, style: const TextStyle(fontSize: 13)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )).toList(),
                    ),
                  ],
                  if (unavailable.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: unavailable.map((s) => Chip(
                        avatar: const Icon(Icons.cancel, size: 16, color: AppColors.error),
                        label: Text(s['name'] as String, style: const TextStyle(fontSize: 13, color: AppColors.grey600)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )).toList(),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
