import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
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
  Map<int, bool> _myDaycareAvailability = {};
  Map<int, bool> _myBoardingAvailability = {};
  Map<int, String> _myNotes = {};
  bool _loadingMy = true;
  bool _saving = false;

  // Calendar state
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  // Coverage tab
  Map<String, dynamic> _coverage = {};
  bool _loadingCoverage = true;

  static const _dayNames = {
    1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday',
    5: 'Friday', 6: 'Saturday', 7: 'Sunday',
  };

  /// Convert DateTime.weekday (1=Mon..7=Sun) to our model key (1=Mon..7=Sun).
  /// They happen to match, but this keeps intent clear.
  int _dayOfWeek(DateTime date) => date.weekday;

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
      final daycare = <int, bool>{};
      final boarding = <int, bool>{};
      final notes = <int, String>{};
      for (final a in avail) {
        daycare[a.dayOfWeek] = a.isAvailableDaycare;
        boarding[a.dayOfWeek] = a.isAvailableBoarding;
        notes[a.dayOfWeek] = a.note;
      }
      // Default to available for days not set
      for (int i = 1; i <= 7; i++) {
        daycare.putIfAbsent(i, () => true);
        boarding.putIfAbsent(i, () => true);
        notes.putIfAbsent(i, () => '');
      }
      if (mounted) {
        setState(() {
          _myDaycareAvailability = daycare;
          _myBoardingAvailability = boarding;
          _myNotes = notes;
          _loadingMy = false;
        });
      }
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
          'is_available_daycare': _myDaycareAvailability[i] ?? true,
          'is_available_boarding': _myBoardingAvailability[i] ?? true,
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
          labelColor: AppColors.cream,
          unselectedLabelColor: AppColors.cream.withAlpha(180),
          indicatorColor: AppColors.cream,
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

  // ── My Availability Tab (Calendar) ──────────────────────────────────

  Widget _buildMyAvailabilityTab() {
    if (_loadingMy) return const Center(child: CircularProgressIndicator());

    final dow = _dayOfWeek(_selectedDay);
    final daycareAvail = _myDaycareAvailability[dow] ?? true;
    final boardingAvail = _myBoardingAvailability[dow] ?? true;

    return Column(
      children: [
        // Format selector
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<CalendarFormat>(
            segments: const [
              ButtonSegment(value: CalendarFormat.month, label: Text('Month')),
              ButtonSegment(value: CalendarFormat.week, label: Text('Week')),
              ButtonSegment(value: CalendarFormat.twoWeeks, label: Text('Day')),
            ],
            selected: {_calendarFormat},
            onSelectionChanged: (selection) {
              setState(() => _calendarFormat = selection.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
        ),

        // Calendar
        TableCalendar(
          firstDay: DateTime.utc(2020, 1, 1),
          lastDay: DateTime.utc(2030, 12, 31),
          focusedDay: _focusedDay,
          calendarFormat: _calendarFormat,
          startingDayOfWeek: StartingDayOfWeek.monday,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          onDaySelected: (selectedDay, focusedDay) {
            setState(() {
              _selectedDay = selectedDay;
              _focusedDay = focusedDay;
            });
          },
          onFormatChanged: (format) {
            setState(() => _calendarFormat = format);
          },
          onPageChanged: (focusedDay) {
            _focusedDay = focusedDay;
          },
          calendarBuilders: CalendarBuilders(
            defaultBuilder: _buildCalendarCell,
            todayBuilder: _buildCalendarCell,
            selectedBuilder: (context, date, focusedDay) {
              return _buildCalendarCell(context, date, focusedDay, isSelected: true);
            },
          ),
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            leftChevronIcon: const Icon(Icons.chevron_left, color: AppColors.primary),
            rightChevronIcon: const Icon(Icons.chevron_right, color: AppColors.primary),
          ),
          daysOfWeekStyle: DaysOfWeekStyle(
            weekdayStyle: TextStyle(color: AppColors.grey600, fontWeight: FontWeight.w600, fontSize: 12),
            weekendStyle: TextStyle(color: AppColors.grey500, fontWeight: FontWeight.w600, fontSize: 12),
          ),
          calendarStyle: const CalendarStyle(
            outsideDaysVisible: false,
            cellMargin: EdgeInsets.all(4),
          ),
        ),

        const Divider(height: 1),

        // Selected day detail panel
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Day header
                Row(
                  children: [
                    _buildStatusIndicator(daycareAvail, boardingAvail),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _dayNames[dow]!,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                          Text(
                            _formatDate(_selectedDay),
                            style: TextStyle(fontSize: 13, color: AppColors.grey600),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_note),
                      onPressed: () => _editNote(dow),
                      tooltip: 'Edit note',
                    ),
                  ],
                ),

                // Note
                if (_myNotes[dow]?.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.grey100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.sticky_note_2_outlined, size: 16, color: AppColors.grey500),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _myNotes[dow]!,
                            style: TextStyle(fontSize: 13, color: AppColors.grey700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                // Service toggles
                _ServiceToggle(
                  label: 'Day Care',
                  icon: Icons.wb_sunny_outlined,
                  value: daycareAvail,
                  onChanged: (val) {
                    setState(() => _myDaycareAvailability[dow] = val);
                  },
                ),
                const SizedBox(height: 8),
                _ServiceToggle(
                  label: 'Boarding',
                  icon: Icons.nightlight_outlined,
                  value: boardingAvail,
                  onChanged: (val) {
                    setState(() => _myBoardingAvailability[dow] = val);
                  },
                ),
              ],
            ),
          ),
        ),

        // Save button
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

  Widget? _buildCalendarCell(BuildContext context, DateTime date, DateTime focusedDay, {bool isSelected = false}) {
    final dow = _dayOfWeek(date);
    final dc = _myDaycareAvailability[dow] ?? true;
    final bd = _myBoardingAvailability[dow] ?? true;

    Color bgColor;
    Color textColor;

    if (isSelected) {
      bgColor = AppColors.primary;
      textColor = Colors.white;
    } else if (dc && bd) {
      bgColor = AppColors.success.withAlpha(30);
      textColor = AppColors.success;
    } else if (dc || bd) {
      bgColor = AppColors.warning.withAlpha(30);
      textColor = AppColors.warning;
    } else {
      bgColor = AppColors.error.withAlpha(30);
      textColor = AppColors.error;
    }

    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${date.day}',
              style: TextStyle(
                color: textColor,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize: 14,
              ),
            ),
            if (!isSelected)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dc ? AppColors.success : AppColors.error,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: bd ? AppColors.success : AppColors.error,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(bool daycare, bool boarding) {
    final both = daycare && boarding;
    final neither = !daycare && !boarding;

    Color color;
    IconData icon;
    if (both) {
      color = AppColors.success;
      icon = Icons.check_circle;
    } else if (neither) {
      color = AppColors.error;
      icon = Icons.cancel;
    } else {
      color = AppColors.warning;
      icon = Icons.remove_circle;
    }

    return CircleAvatar(
      backgroundColor: color.withAlpha(30),
      child: Icon(icon, color: color),
    );
  }

  String _formatDate(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  Future<void> _editNote(int day) async {
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
  }

  // ── Team Coverage Tab ───────────────────────────────────────────────

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
          final daycareAvailable = (dayData['daycare_available'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final daycareUnavailable = (dayData['daycare_unavailable'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final boardingAvailable = (dayData['boarding_available'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final boardingUnavailable = (dayData['boarding_unavailable'] as List?)?.cast<Map<String, dynamic>>() ?? [];

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dayName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  _buildCoverageSection(
                    'Day Care',
                    Icons.wb_sunny_outlined,
                    daycareAvailable,
                    daycareUnavailable,
                  ),
                  const SizedBox(height: 8),
                  _buildCoverageSection(
                    'Boarding',
                    Icons.nightlight_outlined,
                    boardingAvailable,
                    boardingUnavailable,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCoverageSection(
    String title,
    IconData icon,
    List<Map<String, dynamic>> available,
    List<Map<String, dynamic>> unavailable,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: AppColors.grey600),
            const SizedBox(width: 4),
            Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.grey600)),
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
          const SizedBox(height: 4),
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
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: unavailable.map((s) => Chip(
              avatar: const Icon(Icons.cancel, size: 16, color: AppColors.error),
              label: Text(s['name'] as String, style: TextStyle(fontSize: 13, color: AppColors.grey600)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )).toList(),
          ),
        ],
      ],
    );
  }
}

class _ServiceToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ServiceToggle({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: value ? AppColors.success.withAlpha(20) : AppColors.grey100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: value ? AppColors.success.withAlpha(80) : AppColors.grey300,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: value ? AppColors.success : AppColors.grey500),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: value ? AppColors.success : AppColors.grey600,
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.success,
          ),
        ],
      ),
    );
  }
}
