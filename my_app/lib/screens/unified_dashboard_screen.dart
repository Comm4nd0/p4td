import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../constants/app_colors.dart';
import '../models/closure_day.dart';
import '../models/daily_dog_assignment.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';
import '../widgets/dashboard_widgets.dart';
import '../widgets/skeleton_loaders.dart';
import '../widgets/media_tag_dialog.dart';
import 'all_dogs_today_screen.dart';
import 'staff_dog_detail_screen.dart';
import 'staff_notifications_screen.dart';
import 'boarding_request_list_screen.dart';
import 'query_list_screen.dart';
import 'inquiry_list_screen.dart';
import 'dog_profile_changes_screen.dart';

class UnifiedDashboardScreen extends StatefulWidget {
  final bool canAssignDogs;
  final bool canManageRequests;
  final bool canReplyQueries;
  final bool canViewInquiries;
  final bool canAddFeedMedia;
  final bool isStaff;
  final int? myUserId;
  final int? initialStaffId;
  /// Callback to switch to feed tab (index 1)
  final VoidCallback? onSwitchToFeed;

  const UnifiedDashboardScreen({
    super.key,
    this.canAssignDogs = false,
    this.canManageRequests = false,
    this.canReplyQueries = false,
    this.canViewInquiries = false,
    this.canAddFeedMedia = false,
    this.isStaff = false,
    this.myUserId,
    this.initialStaffId,
    this.onSwitchToFeed,
  });

  @override
  State<UnifiedDashboardScreen> createState() => UnifiedDashboardScreenState();
}

class UnifiedDashboardScreenState extends State<UnifiedDashboardScreen> {
  final DataService _dataService = ApiDataService();

  // Assignment cache
  final Map<String, List<DailyDogAssignment>> _assignmentCache = {};
  final Set<String> _loadingDates = {};

  // Scheduled dogs that are not yet assigned for a date, excluding ad-hoc
  // dogs (those are shown to admins separately). Used both for the
  // unassigned banner count and the All Dogs view.
  final Map<String, List<Dog>> _unassignedDogsCache = {};

  // Date navigation
  List<DateTime> _dateOptions = [];
  late PageController _pageController;
  final ScrollController _dateScrollController = ScrollController();
  late DateTime _selectedDate;

  // Closure days
  Map<DateTime, ClosureDay> _closureDays = {};

  // Staff
  List<Map<String, dynamic>> _staffMembers = [];
  Set<int> _availableStaffIds = {};

  // Dashboard data
  int _pendingRequestCount = 0;
  int _unresolvedQueryCount = 0;
  int _unreadInquiryCount = 0;
  int _pendingProfileChangeCount = 0;
  List<BoardingRequest> _boardingTonight = [];

  @override
  void initState() {
    super.initState();
    _dateOptions = _generateWeekdays(DateTime.now());
    final today = DateTime.now();
    final todayIndex = _dateOptions.indexWhere((d) => _isSameDay(d, today));
    final initialIndex = todayIndex >= 0 ? todayIndex : 0;
    _selectedDate = _dateOptions[initialIndex];
    _pageController = PageController(initialPage: initialIndex);
    _loadStaffMembers();
    _loadAssignmentsForDate(_selectedDate);
    _loadClosureDays();
    _loadDashboardData();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _dateScrollController.dispose();
    super.dispose();
  }

  // ─── Date generation ──────────────────────────────────────────────

  List<DateTime> _generateWeekdays(DateTime centerDate) {
    var start = DateTime(centerDate.year, centerDate.month, centerDate.day);
    if (start.weekday == DateTime.saturday) {
      start = start.add(const Duration(days: 2));
    } else if (start.weekday == DateTime.sunday) {
      start = start.add(const Duration(days: 1));
    }
    final List<DateTime> weekdays = [];
    var current = start;
    while (weekdays.length < 10) {
      if (current.weekday >= DateTime.monday && current.weekday <= DateTime.friday) {
        weekdays.add(current);
      }
      current = current.add(const Duration(days: 1));
    }
    return weekdays;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dateKey(DateTime date) => '${date.year}-${date.month}-${date.day}';

  // ─── Data loading ─────────────────────────────────────────────────

  Future<void> _loadStaffMembers() async {
    try {
      final staff = await _dataService.getStaffMembers();
      if (mounted) setState(() => _staffMembers = staff);
      _loadAvailableStaff(_selectedDate);
    } catch (_) {}
  }

  Future<void> _loadAvailableStaff(DateTime date) async {
    try {
      final available = await _dataService.getAvailableStaffForDate(date);
      if (mounted) setState(() => _availableStaffIds = available.map((s) => s['id'] as int).toSet());
    } catch (_) {
      if (mounted) setState(() => _availableStaffIds = _staffMembers.map((s) => s['id'] as int).toSet());
    }
  }

  Future<void> _loadClosureDays() async {
    try {
      final firstDate = _dateOptions.first;
      final lastDate = _dateOptions.last;
      final closures = await _dataService.getClosureDays(fromDate: firstDate, toDate: lastDate);
      if (mounted) {
        final closureMap = <DateTime, ClosureDay>{};
        for (final c in closures) {
          closureMap[DateTime(c.date.year, c.date.month, c.date.day)] = c;
        }
        setState(() {
          _closureDays = closureMap;
          final closedDates = closureMap.entries
              .where((e) => e.value.closureType == ClosureType.closed)
              .map((e) => e.key)
              .toSet();
          _dateOptions = _dateOptions
              .where((d) => !closedDates.contains(DateTime(d.year, d.month, d.day)))
              .toList();
          if (!_dateOptions.any((d) => _isSameDay(d, _selectedDate)) && _dateOptions.isNotEmpty) {
            _selectedDate = _dateOptions.first;
            _pageController.jumpToPage(0);
            _loadAssignmentsForDate(_selectedDate);
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _loadAssignmentsForDate(DateTime date, {bool forceReload = false}) async {
    if (!mounted) return;
    final key = _dateKey(date);
    if (!forceReload && _assignmentCache.containsKey(key)) return;
    setState(() => _loadingDates.add(key));
    try {
      final assignments = await _dataService.getTodayAssignments(date: date);
      if (mounted) {
        setState(() {
          _assignmentCache[key] = assignments;
          _loadingDates.remove(key);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingDates.remove(key));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load assignments: $e')));
      }
    }
    _loadUnassignedCountForDate(date, forceReload: forceReload);
  }

  Future<void> _loadUnassignedCountForDate(DateTime date, {bool forceReload = false}) async {
    final key = _dateKey(date);
    if (!forceReload && _unassignedDogsCache.containsKey(key)) return;
    try {
      final unassigned = await _dataService.getUnassignedDogs(date: date);
      final nonAdHoc = unassigned.where((d) => d.scheduleType != ScheduleType.adHoc).toList();
      if (mounted) setState(() => _unassignedDogsCache[key] = nonAdHoc);
    } catch (_) {}
  }

  Future<void> _loadAssignments() {
    _assignmentCache.clear();
    _unassignedDogsCache.clear();
    return _loadAssignmentsForDate(_selectedDate, forceReload: true);
  }

  Future<void> _loadDashboardData() async {
    _loadPendingRequestCount();
    _loadUnresolvedQueryCount();
    if (widget.canViewInquiries) _loadUnreadInquiryCount();
    _loadBoardingTonight();
    if (widget.canManageRequests) _loadPendingProfileChangeCount();
  }

  Future<void> _loadPendingProfileChangeCount() async {
    try {
      final count = await _dataService.getPendingDogProfileChangeCount();
      if (mounted) setState(() => _pendingProfileChangeCount = count);
    } catch (_) {}
  }

  Future<void> _loadPendingRequestCount() async {
    try {
      final dateRequests = await _dataService.getDateChangeRequests();
      final boardingRequests = await _dataService.getBoardingRequests();
      final pendingDateCount = dateRequests.where((r) => r.status == RequestStatus.pending).length;
      final pendingBoardingCount = boardingRequests.where((r) => r.status == BoardingRequestStatus.pending).length;
      if (mounted) setState(() => _pendingRequestCount = pendingDateCount + pendingBoardingCount);
    } catch (_) {}
  }

  Future<void> _loadUnresolvedQueryCount() async {
    try {
      final count = await _dataService.getUnresolvedQueryCount();
      if (mounted) setState(() => _unresolvedQueryCount = count);
    } catch (_) {}
  }

  Future<void> _loadUnreadInquiryCount() async {
    try {
      final count = await _dataService.getUnreadInquiryCount();
      if (mounted) setState(() => _unreadInquiryCount = count);
    } catch (_) {}
  }

  Future<void> _loadBoardingTonight() async {
    try {
      final requests = await _dataService.getBoardingRequests();
      final today = DateTime.now();
      final tonight = DateTime(today.year, today.month, today.day);
      if (mounted) {
        setState(() {
          _boardingTonight = requests.where((r) =>
            r.status == BoardingRequestStatus.approved &&
            !r.startDate.isAfter(tonight) &&
            r.endDate.isAfter(tonight)
          ).toList();
        });
      }
    } catch (_) {}
  }

  // ─── Public methods for parent FABs ───────────────────────────────

  void assignDogs() => _showAssignDogsDialog();
  void showSwapStaffDialog() => _showSwapStaffDialog();

  void filterByStaff(int? staffId) {
    if (staffId != null) {
      final assignments = _assignmentCache[_dateKey(_selectedDate)] ?? [];
      final staffAssignments = assignments.where((a) => a.staffMemberId == staffId).toList();
      final staffName = _staffMembers
          .where((s) => s['id'] == staffId)
          .map((s) => (s['first_name']?.toString().isNotEmpty == true ? s['first_name'] : s['username']).toString())
          .firstOrNull ?? 'Staff';
      _navigateToStaffDetail(staffId, staffName, staffAssignments);
    }
  }

  // ─── Date picker ──────────────────────────────────────────────────

  Future<void> _showDatePicker() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 7)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      selectableDayPredicate: (date) =>
          date.weekday >= DateTime.monday && date.weekday <= DateTime.friday,
    );
    if (picked == null) return;

    // Check if picked date is within current date options
    final existingIndex = _dateOptions.indexWhere((d) => _isSameDay(d, picked));
    if (existingIndex >= 0) {
      setState(() => _selectedDate = picked);
      _pageController.animateToPage(existingIndex, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      _loadAssignmentsForDate(picked);
      _loadAvailableStaff(picked);
    } else {
      // Regenerate date options centered on picked date
      setState(() {
        _dateOptions = _generateWeekdays(picked);
        _selectedDate = picked;
        final newIndex = _dateOptions.indexWhere((d) => _isSameDay(d, picked));
        _pageController = PageController(initialPage: newIndex >= 0 ? newIndex : 0);
      });
      _loadAssignmentsForDate(picked);
      _loadAvailableStaff(picked);
      _loadClosureDays();
    }
  }

  // ─── Navigation ────────────────────────────────────────────────────

  Future<void> _navigateToAllDogs(
    List<DailyDogAssignment> assignments,
    List<Dog> unassignedDogs,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AllDogsTodayScreen(
          date: _selectedDate,
          assignments: assignments,
          unassignedDogs: unassignedDogs,
          canAssignDogs: widget.canAssignDogs,
          isStaff: widget.isStaff,
          staffMembers: _staffMembers,
          availableStaffIds: _availableStaffIds,
        ),
      ),
    );
    // Refresh after returning — statuses may have changed
    if (mounted) {
      await _loadAssignmentsForDate(_selectedDate, forceReload: true);
    }
  }

  Future<void> _navigateToStaffDetail(int? staffId, String staffName, List<DailyDogAssignment> assignments) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StaffDogDetailScreen(
          staffMemberId: staffId,
          staffMemberName: staffName,
          date: _selectedDate,
          assignments: assignments,
          canAssignDogs: widget.canAssignDogs,
        ),
      ),
    );
    // Always refresh after returning — data may have changed
    if (mounted) {
      await _loadAssignmentsForDate(_selectedDate, forceReload: true);
    }
  }

  // ─── Assign dogs dialog ───────────────────────────────────────────

  Future<void> _showAssignDogsDialog() async {
    List<Dog> unassigned;
    Map<String, dynamic> suggestions = {};
    try {
      unassigned = await _dataService.getUnassignedDogs(date: _selectedDate);
      if (widget.canAssignDogs) {
        suggestions = await _dataService.getSuggestedAssignments(date: _selectedDate);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load data: $e')));
      }
      return;
    }

    if (!mounted) return;
    final dateLabel = _isSameDay(_selectedDate, DateTime.now())
        ? 'today'
        : ukDateWithDay(_selectedDate);

    if (unassigned.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('All dogs scheduled for $dateLabel are already assigned.')),
      );
      return;
    }

    // Let the user pick a staff member first if they have permission
    int? targetStaffId;
    String? staffName;
    if (widget.canAssignDogs) {
      if (_staffMembers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No staff members loaded.')));
        return;
      }
      targetStaffId = await _pickStaffMember();
      if (targetStaffId == null) return;
      final staff = _staffMembers.firstWhere((s) => s['id'] == targetStaffId, orElse: () => {});
      staffName = (staff['first_name'] != null && staff['first_name'].toString().isNotEmpty)
          ? staff['first_name'].toString()
          : staff['username']?.toString();
    }

    if (!mounted) return;

    final selected = <int>{};
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(widget.canAssignDogs
              ? 'Assign Dogs to $staffName ($dateLabel)'
              : 'Assign Dogs to Me ($dateLabel)'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: unassigned.length,
              itemBuilder: (context, index) {
                final dog = unassigned[index];
                final dogId = int.parse(dog.id);
                final suggestion = suggestions[dogId.toString()];
                String? suggestedName;
                String suggestedLabel = 'Last week';
                if (suggestion != null) {
                  suggestedName = suggestion['staff_member_name'];
                  if (suggestion['source'] == 'frequency') suggestedLabel = 'Usually';
                }
                return CheckboxListTile(
                  value: selected.contains(dogId),
                  onChanged: (checked) {
                    setDialogState(() {
                      if (checked == true) selected.add(dogId); else selected.remove(dogId);
                    });
                  },
                  title: Row(children: [
                    Flexible(child: Text(dog.name)),
                    if (dog.scheduleType == ScheduleType.adHoc) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('Ad Hoc', style: TextStyle(fontSize: 11, color: Colors.orange[800], fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ]),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dog.ownerDetails != null) Text('Owner: ${dog.ownerDetails!.username}'),
                      if (suggestedName != null)
                        Text('$suggestedLabel: $suggestedName',
                            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12, fontStyle: FontStyle.italic)),
                    ],
                  ),
                  secondary: dog.profileImageUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: CachedNetworkImage(imageUrl: dog.profileImageUrl!, width: 40, height: 40, fit: BoxFit.cover),
                        )
                      : CircleAvatar(child: PhosphorIcon(PhosphorIconsDuotone.pawPrint)),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: selected.isEmpty ? null : () => Navigator.pop(context, true), child: const Text('Assign')),
          ],
        ),
      ),
    );

    if (result == true && selected.isNotEmpty) {
      try {
        final AssignDogsResult assignResult;
        if (widget.canAssignDogs && targetStaffId != null) {
          assignResult = await _dataService.assignDogs(selected.toList(), targetStaffId, date: _selectedDate);
        } else {
          assignResult = await _dataService.assignDogsToMe(selected.toList(), date: _selectedDate);
        }
        if (mounted && assignResult.hasSkipped) {
          final names = assignResult.skipped.map((s) => s.dogName).join(', ');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Already assigned: $names'), backgroundColor: Colors.orange, duration: const Duration(seconds: 4)),
          );
        }
        await _loadAssignments();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to assign dogs: $e')));
        }
      }
    }
  }

  Future<int?> _pickStaffMember() async {
    int? picked;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Select Staff Member'),
          content: DropdownButtonFormField<int>(
            decoration: const InputDecoration(labelText: 'Assign to', border: OutlineInputBorder()),
            items: _staffMembers.map((s) {
              final name = (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
                  ? s['first_name'].toString() : s['username'].toString();
              final staffId = s['id'] as int;
              final isAvailable = _availableStaffIds.isEmpty || _availableStaffIds.contains(staffId);
              return DropdownMenuItem<int>(
                value: staffId,
                child: Row(children: [
                  Icon(PhosphorIconsDuotone.circle, size: 10, color: isAvailable ? AppColors.success : AppColors.grey400),
                  const SizedBox(width: 8),
                  Text(name, style: TextStyle(color: isAvailable ? null : AppColors.grey500)),
                  if (!isAvailable) Text(' (off)', style: TextStyle(fontSize: 11, color: AppColors.grey400)),
                ]),
              );
            }).toList(),
            onChanged: (v) => setDialogState(() => picked = v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: picked == null ? null : () => Navigator.pop(context, true), child: const Text('Next')),
          ],
        ),
      ),
    );
    return (result == true) ? picked : null;
  }

  // ─── Swap staff dialog ────────────────────────────────────────────

  Future<void> _showSwapStaffDialog() async {
    if (!widget.canAssignDogs) return;

    List<Map<String, dynamic>> staffMembers;
    try {
      staffMembers = await _dataService.getStaffMembers();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load staff: $e')));
      return;
    }
    if (staffMembers.length < 2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Need at least two staff members to swap.')));
      return;
    }
    if (!mounted) return;

    int? fromStaffId;
    int? toStaffId;
    SwapScope scope = SwapScope.justThisDay;
    int? previewCount;
    bool loadingPreview = false;

    String staffLabel(Map<String, dynamic> s) =>
        (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
            ? s['first_name'].toString() : s['username'].toString();

    Future<void> refreshPreview(void Function(void Function()) setDialogState) async {
      if (fromStaffId == null || scope == SwapScope.justThisDay) {
        setDialogState(() => previewCount = null);
        return;
      }
      setDialogState(() => loadingPreview = true);
      try {
        final roster = await _dataService.getWeekdayRoster(
          weekday: scope == SwapScope.thisWeekdayForever ? _selectedDate.weekday : null,
          staffMemberId: fromStaffId,
        );
        if (mounted) setDialogState(() { previewCount = roster.length; loadingPreview = false; });
      } catch (_) {
        setDialogState(() { previewCount = null; loadingPreview = false; });
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Swap Staff'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'From staff', border: OutlineInputBorder()),
                  value: fromStaffId,
                  items: staffMembers.map((s) => DropdownMenuItem<int>(value: s['id'] as int, child: Text(staffLabel(s)))).toList(),
                  onChanged: (v) { setDialogState(() => fromStaffId = v); refreshPreview(setDialogState); },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'To staff', border: OutlineInputBorder()),
                  value: toStaffId,
                  items: staffMembers.where((s) => s['id'] != fromStaffId)
                      .map((s) => DropdownMenuItem<int>(value: s['id'] as int, child: Text(staffLabel(s)))).toList(),
                  onChanged: (v) => setDialogState(() => toStaffId = v),
                ),
                const SizedBox(height: 16),
                const Text('Scope', style: TextStyle(fontWeight: FontWeight.bold)),
                RadioListTile<SwapScope>(
                  contentPadding: EdgeInsets.zero, dense: true,
                  title: Text('Just ${ukDateWithDay(_selectedDate)}'),
                  value: SwapScope.justThisDay, groupValue: scope,
                  onChanged: (v) { setDialogState(() => scope = v!); refreshPreview(setDialogState); },
                ),
                RadioListTile<SwapScope>(
                  contentPadding: EdgeInsets.zero, dense: true,
                  title: Text('Every ${DateFormat('EEEE').format(_selectedDate)} from now on'),
                  value: SwapScope.thisWeekdayForever, groupValue: scope,
                  onChanged: (v) { setDialogState(() => scope = v!); refreshPreview(setDialogState); },
                ),
                RadioListTile<SwapScope>(
                  contentPadding: EdgeInsets.zero, dense: true,
                  title: const Text('All weekdays from now on'),
                  value: SwapScope.allWeekdaysForever, groupValue: scope,
                  onChanged: (v) { setDialogState(() => scope = v!); refreshPreview(setDialogState); },
                ),
                if (scope != SwapScope.justThisDay) ...[
                  const SizedBox(height: 8),
                  if (loadingPreview)
                    const Text('Loading affected dog count…')
                  else if (previewCount != null)
                    Text('$previewCount roster entr${previewCount == 1 ? 'y' : 'ies'} will be flipped.',
                        style: const TextStyle(fontStyle: FontStyle.italic)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: (fromStaffId == null || toStaffId == null) ? null : () => Navigator.pop(context, true),
              child: const Text('Swap'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || fromStaffId == null || toStaffId == null) return;
    try {
      final result = await _dataService.swapStaff(
        fromStaffId: fromStaffId!, toStaffId: toStaffId!,
        scope: scope, date: scope == SwapScope.allWeekdaysForever ? null : _selectedDate,
      );
      if (mounted) {
        final updated = result['assignment_rows_updated'] ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Swapped $updated assignment(s).'), backgroundColor: Colors.green),
        );
      }
      await _loadAssignments();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to swap staff: $e')));
    }
  }

  // ─── Add dog to day dialog ────────────────────────────────────────

  Future<void> _showAddDogToDayDialog() async {
    List<Dog> allDogs;
    List<Dog> unassigned;
    List<DailyDogAssignment> currentAssignments;
    try {
      allDogs = await _dataService.getDogs();
      unassigned = await _dataService.getUnassignedDogs(date: _selectedDate);
      // Fetch fresh from the API — never rely on the local cache here
      currentAssignments = await _dataService.getTodayAssignments(date: _selectedDate);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load dogs: $e')));
      return;
    }
    if (!mounted) return;

    // Get IDs of dogs already assigned for this date (fresh from API)
    final assignedDogIds = currentAssignments.map((a) => a.dogId).toSet();
    final unassignedDogIds = unassigned.map((d) => int.parse(d.id)).toSet();

    // Extra dogs = all dogs minus already assigned minus unassigned (i.e. dogs not booked at all)
    final extraDogs = allDogs.where((d) {
      final dogId = int.parse(d.id);
      return !assignedDogIds.contains(dogId) && !unassignedDogIds.contains(dogId);
    }).toList();

    final dateLabel = ukDateWithDay(_selectedDate);
    int? selectedDogId;
    int? selectedStaffId;
    final searchController = TextEditingController();
    List<Dog> filteredExtraDogs = List.of(extraDogs);

    final sortedStaff = List<Map<String, dynamic>>.from(_staffMembers)
      ..sort((a, b) {
        final aAvail = _availableStaffIds.isEmpty || _availableStaffIds.contains(a['id'] as int);
        final bAvail = _availableStaffIds.isEmpty || _availableStaffIds.contains(b['id'] as int);
        if (aAvail && !bAvail) return -1;
        if (!aAvail && bAvail) return 1;
        return 0;
      });

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text('Add Dog to $dateLabel'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.canAssignDogs) ...[
                      DropdownButtonFormField<int>(
                        decoration: const InputDecoration(labelText: 'Assign to staff', border: OutlineInputBorder()),
                        value: selectedStaffId,
                        items: sortedStaff.map((s) {
                          final name = (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
                              ? s['first_name'].toString() : s['username'].toString();
                          final staffId = s['id'] as int;
                          final isAvailable = _availableStaffIds.isEmpty || _availableStaffIds.contains(staffId);
                          return DropdownMenuItem<int>(
                            value: staffId,
                            child: Row(children: [
                              Icon(PhosphorIconsDuotone.circle, size: 10, color: isAvailable ? AppColors.success : AppColors.grey400),
                              const SizedBox(width: 8),
                              Text(name, style: TextStyle(color: isAvailable ? null : AppColors.grey500)),
                              if (!isAvailable) Text(' (off)', style: TextStyle(fontSize: 11, color: AppColors.grey400)),
                            ]),
                          );
                        }).toList(),
                        onChanged: (v) => setDialogState(() => selectedStaffId = v),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const Text('Search for a dog to add to this day:', style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        hintText: 'Search by name...',
                        prefixIcon: PhosphorIcon(PhosphorIconsDuotone.magnifyingGlass),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      ),
                      onChanged: (query) {
                        setDialogState(() {
                          filteredExtraDogs = extraDogs
                              .where((d) => d.name.toLowerCase().contains(query.toLowerCase()))
                              .toList();
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.3),
                      child: filteredExtraDogs.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text('No additional dogs found', style: TextStyle(color: Colors.grey[500])),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: filteredExtraDogs.length,
                              itemBuilder: (context, index) {
                                final dog = filteredExtraDogs[index];
                                final dogId = int.parse(dog.id);
                                return RadioListTile<int>(
                                  value: dogId,
                                  groupValue: selectedDogId,
                                  onChanged: (v) => setDialogState(() => selectedDogId = v),
                                  title: Text(dog.name),
                                  subtitle: dog.ownerDetails != null ? Text('Owner: ${dog.ownerDetails!.username}') : null,
                                  secondary: dog.profileImageUrl != null
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(20),
                                          child: CachedNetworkImage(imageUrl: dog.profileImageUrl!, width: 40, height: 40, fit: BoxFit.cover),
                                        )
                                      : CircleAvatar(child: PhosphorIcon(PhosphorIconsDuotone.pawPrint)),
                                  dense: true,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(
                onPressed: selectedDogId == null || (widget.canAssignDogs && selectedStaffId == null)
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Add to Day'),
              ),
            ],
          );
        },
      ),
    );

    if (result == true && selectedDogId != null) {
      try {
        final AssignDogsResult assignResult;
        if (widget.canAssignDogs && selectedStaffId != null) {
          assignResult = await _dataService.assignDogs([selectedDogId!], selectedStaffId!, date: _selectedDate);
        } else {
          assignResult = await _dataService.assignDogsToMe([selectedDogId!], date: _selectedDate);
        }
        if (mounted) {
          if (assignResult.hasSkipped) {
            final reason = assignResult.skipped.first.reason;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${assignResult.skipped.first.dogName} - $reason'), backgroundColor: Colors.orange),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Dog added to day'), backgroundColor: Colors.green),
            );
          }
        }
        await _loadAssignments();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to add dog: $e')));
      }
    }
  }

  // ─── Upload media from dashboard ──────────────────────────────────

  Future<void> _uploadMediaFromDashboard() async {
    final picker = ImagePicker();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: PhosphorIcon(PhosphorIconsDuotone.camera), title: const Text('Take Photo'), onTap: () => Navigator.pop(context, 'camera_photo')),
            ListTile(leading: PhosphorIcon(PhosphorIconsDuotone.videoCamera), title: const Text('Record Video'), onTap: () => Navigator.pop(context, 'camera_video')),
            const Divider(),
            ListTile(leading: PhosphorIcon(PhosphorIconsDuotone.uploadSimple), title: const Text('Upload'), onTap: () => Navigator.pop(context, 'multiple')),
          ],
        ),
      ),
    );
    if (choice == null) return;

    if (choice == 'multiple') {
      final files = await picker.pickMultipleMedia();
      if (files.isEmpty) return;

      final tagDialogFiles = <(Uint8List, String, bool)>[];
      final fileData = <(Uint8List, String)>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final ext = file.name.toLowerCase();
        final isVideo = ext.endsWith('.mp4') || ext.endsWith('.mov') || ext.endsWith('.avi');
        tagDialogFiles.add((bytes, file.name, isVideo));
        fileData.add((bytes, file.name));
      }

      // Ask whether to tag or upload straight away
      if (!mounted) return;
      final wantTag = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${files.length} file${files.length == 1 ? '' : 's'} selected'),
          content: const Text('Would you like to tag dogs and add a caption, or upload straight away?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Upload Now')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tag & Caption')),
          ],
        ),
      );
      if (wantTag == null) return;

      List<String?>? captionsByFile;
      List<List<String>>? taggedDogIdsByFile;

      if (wantTag) {
        final tagResult = await Navigator.push<MediaTagResult>(
          context,
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => MediaTagDialog(files: tagDialogFiles)),
        );
        if (tagResult == null) return;
        captionsByFile = tagResult.captionsByFile;
        taggedDogIdsByFile = tagResult.taggedDogIdsByFile;
      }

      final progress = ValueNotifier<int>(0);
      final total = files.length;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (context, completed, _) => AlertDialog(
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Uploading $completed/$total...'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: total > 0 ? completed / total : 0),
              ]),
            ),
          ),
        ),
      );

      try {
        await _dataService.uploadMultipleGroupMedia(
          files: fileData, captionsByFile: captionsByFile,
          taggedDogIdsByFile: taggedDogIdsByFile,
          onProgress: (done, count) => progress.value = done,
        );
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Successfully uploaded $total file${total == 1 ? '' : 's'}!'), backgroundColor: Colors.green));
        }
      } catch (e) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red));
        }
      }
      return;
    }

    XFile? file;
    final isVideo = choice.contains('video');
    final source = choice.contains('camera') ? ImageSource.camera : ImageSource.gallery;
    if (isVideo) {
      file = await picker.pickVideo(source: source);
    } else {
      file = await picker.pickImage(source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 85);
    }
    if (file == null) return;

    final bytes = await file.readAsBytes();
    final tagResult = await Navigator.push<MediaTagResult>(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => MediaTagDialog(files: [(bytes, file!.name, isVideo)])),
    );
    if (tagResult == null) return;

    try {
      showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Text('Uploading...')])));
      await _dataService.uploadGroupMedia(
        fileBytes: bytes, fileName: file.name, isVideo: isVideo,
        caption: tagResult.caption,
        taggedDogIds: tagResult.taggedDogIdsByFile.isNotEmpty ? tagResult.taggedDogIdsByFile[0] : null,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload successful!'), backgroundColor: Colors.green));
          }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // ─── Helper: scroll date chip into view ───────────────────────────

  void _scrollToDateChip(int index) {
    final targetOffset = (index * 78.0) - 100;
    if (_dateScrollController.hasClients) {
      _dateScrollController.animateTo(
        targetOffset.clamp(0.0, _dateScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // ─── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildDateSelector(),
        // Reduced capacity warning
        if (_closureDays[DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)]?.closureType == ClosureType.reduced)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(children: [
              PhosphorIcon(PhosphorIconsDuotone.warning, size: 18, color: Colors.orange[700]),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Reduced capacity${_closureDays[DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)]?.reason.isNotEmpty == true ? ' – ${_closureDays[DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)]!.reason}' : ''}',
                  style: TextStyle(color: Colors.orange[800], fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
            ]),
          ),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _dateOptions.length,
            onPageChanged: (index) {
              final date = _dateOptions[index];
              setState(() => _selectedDate = date);
              _scrollToDateChip(index);
              _loadAssignmentsForDate(date);
              _loadAvailableStaff(date);
            },
            itemBuilder: (context, index) {
              final date = _dateOptions[index];
              final key = _dateKey(date);
              final isLoading = _loadingDates.contains(key);
              final assignments = _assignmentCache[key] ?? [];

              if (isLoading && !_assignmentCache.containsKey(key)) {
                return const ListTileSkeletonList();
              }

              return RefreshIndicator(
                onRefresh: () async {
                  await _loadAssignmentsForDate(date, forceReload: true);
                  await _loadDashboardData();
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildUnassignedBanner(date),
                    _buildOverviewMetrics(assignments),
                    const SizedBox(height: 16),
                    _buildStaffCards(assignments),
                    const SizedBox(height: 16),
                    _buildActionItems(),
                    const SizedBox(height: 16),
                    // Add Dog to Day button
                    if (widget.canAssignDogs)
                      OutlinedButton.icon(
                        onPressed: _showAddDogToDayDialog,
                        icon: PhosphorIcon(PhosphorIconsDuotone.plusCircle),
                        label: const Text('Add Dog to Day'),
                      ),
                    const SizedBox(height: 16),
                    _buildBoardingSection(),
                    const SizedBox(height: 16),
                    _buildQuickActions(),
                    const SizedBox(height: 80), // space for FABs
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDateSelector() {
    final today = DateTime.now();
    final dateFormat = DateFormat('EEE');
    final dayFormat = DateFormat('d');

    return SizedBox(
      height: 72,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _dateScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _dateOptions.length,
              itemBuilder: (context, index) {
                final date = _dateOptions[index];
                final isSelected = _isSameDay(date, _selectedDate);
                final isToday = _isSameDay(date, today);
                final closure = _closureDays[DateTime(date.year, date.month, date.day)];
                final isReduced = closure?.closureType == ClosureType.reduced;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    selected: isSelected,
                    onSelected: (_) {
                      setState(() => _selectedDate = date);
                      _pageController.animateToPage(index, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                      _loadAssignmentsForDate(date);
                      _loadAvailableStaff(date);
                    },
                    label: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(isToday ? 'Today' : dateFormat.format(date),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isReduced && !isSelected ? Colors.orange[700] : null,
                            )),
                        Text(dayFormat.format(date),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isReduced && !isSelected ? Colors.orange[700] : null,
                            )),
                        if (isReduced)
                          Text('Reduced',
                              style: TextStyle(fontSize: 9, color: isSelected ? null : Colors.orange[700], fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // Date picker button
          IconButton(
            icon: PhosphorIcon(PhosphorIconsDuotone.calendarBlank),
            tooltip: 'Pick a date',
            onPressed: _showDatePicker,
          ),
        ],
      ),
    );
  }

  Widget _buildUnassignedBanner(DateTime date) {
    final count = _unassignedDogsCache[_dateKey(date)]?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    final label = count == 1 ? '1 dog unassigned' : '$count dogs unassigned';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.red.shade600,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.canAssignDogs || widget.isStaff ? _showAssignDogsDialog : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                PhosphorIcon(PhosphorIconsDuotone.warning, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
                PhosphorIcon(PhosphorIconsDuotone.caretRight, color: Colors.white, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewMetrics(List<DailyDogAssignment> assignments) {
    final unassignedDogs = _unassignedDogsCache[_dateKey(_selectedDate)] ?? const <Dog>[];
    final uniqueAssignedDogs = assignments.map((a) => a.dogId).toSet().length;
    final allDogsCount = uniqueAssignedDogs + unassignedDogs.length;
    final myDogs = widget.myUserId != null
        ? assignments.where((a) => a.staffMemberId == widget.myUserId).length
        : 0;
    final boardingCount = assignments.where((a) => a.isBoarding).length;

    return Row(children: [
      Expanded(child: OverviewCard(
        compact: true,
        icon: PhosphorIconsDuotone.pawPrint,
        value: '$allDogsCount',
        label: 'All Dogs',
        color: AppColors.primary,
        onTap: () => _navigateToAllDogs(assignments, unassignedDogs),
      )),
      const SizedBox(width: 6),
      Expanded(child: OverviewCard(
        compact: true,
        icon: PhosphorIconsDuotone.user,
        value: '$myDogs',
        label: 'My Dogs',
        color: AppColors.primary,
        onTap: widget.myUserId != null ? () => filterByStaff(widget.myUserId) : null,
      )),
      const SizedBox(width: 6),
      Expanded(child: OverviewCard(
        compact: true,
        icon: PhosphorIconsDuotone.clipboardText,
        value: '${assignments.length}',
        label: 'Assigned',
        color: AppColors.info,
      )),
      const SizedBox(width: 6),
      Expanded(child: OverviewCard(
        compact: true,
        icon: PhosphorIconsDuotone.bed,
        value: '$boardingCount',
        label: 'Boarding',
        color: AppColors.primaryLight,
      )),
    ]);
  }

  Widget _buildActionItems() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Action Items', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ActionItemTile(
          icon: PhosphorIconsDuotone.clockCountdown,
          label: 'Pending Requests',
          count: _pendingRequestCount,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(
              builder: (_) => StaffNotificationsScreen(canManageRequests: widget.canManageRequests),
            ));
            _loadPendingRequestCount();
          },
        ),
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PhosphorIconsDuotone.chats,
          label: 'Unresolved Queries',
          count: _unresolvedQueryCount,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(
              builder: (_) => QueryListScreen(isStaff: widget.isStaff, canReplyQueries: widget.canReplyQueries),
            ));
            _loadUnresolvedQueryCount();
          },
        ),
        if (widget.canViewInquiries) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PhosphorIconsDuotone.envelope,
            label: 'Unread Inquiries',
            count: _unreadInquiryCount,
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const InquiryListScreen()));
              _loadUnreadInquiryCount();
            },
          ),
        ],
        if (widget.canManageRequests) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PhosphorIconsDuotone.dog,
            label: 'Profile Changes',
            count: _pendingProfileChangeCount,
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const DogProfileChangesScreen()));
              _loadPendingProfileChangeCount();
            },
          ),
        ],
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PhosphorIconsDuotone.bed,
          label: 'Boarding Requests',
          count: _boardingTonight.length,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BoardingRequestListScreen())),
        ),
      ],
    );
  }

  Widget _buildStaffCards(List<DailyDogAssignment> assignments) {
    // Group by staff member
    final Map<int, _StaffSummary> staffMap = {};
    for (final a in assignments) {
      staffMap.putIfAbsent(a.staffMemberId, () => _StaffSummary(a.staffMemberId, a.staffMemberName));
      staffMap[a.staffMemberId]!.dogCount++;
      staffMap[a.staffMemberId]!.assignments.add(a);
    }
    final staffList = staffMap.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (staffList.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(child: Text('No dogs assigned for this date', style: TextStyle(color: Colors.grey[500]))),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Staff', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...staffList.map((staff) {
          final isAvailable = _availableStaffIds.isEmpty || _availableStaffIds.contains(staff.id);
          final ownerBringsCount = staff.assignments.where((a) => a.effectiveOwnerBrings).length;
          final ownerCollectsCount = staff.assignments.where((a) => a.effectiveOwnerCollects).length;
          final hasOwnerTransport = ownerBringsCount > 0 || ownerCollectsCount > 0;
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.primary,
                child: Text(staff.name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              title: Row(children: [
                Text(staff.name),
                if (!isAvailable) ...[
                  const SizedBox(width: 6),
                  Text('(off)', style: TextStyle(fontSize: 11, color: AppColors.grey400)),
                ],
              ]),
              subtitle: hasOwnerTransport
                  ? Row(children: [
                      const PhosphorIcon(PhosphorIconsDuotone.houseLine, size: 13, color: Colors.teal),
                      const SizedBox(width: 3),
                      Text(
                        [
                          if (ownerBringsCount > 0) '$ownerBringsCount drop-off${ownerBringsCount == 1 ? '' : 's'}',
                          if (ownerCollectsCount > 0) '$ownerCollectsCount pick-up${ownerCollectsCount == 1 ? '' : 's'}',
                        ].join(', '),
                        style: const TextStyle(fontSize: 11, color: Colors.teal),
                      ),
                    ])
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Chip(
                    label: Text('${staff.dogCount} dog${staff.dogCount == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                    backgroundColor: AppColors.primary,
                  ),
                  const SizedBox(width: 4),
                  PhosphorIcon(PhosphorIconsDuotone.caretRight),
                ],
              ),
              onTap: () => _navigateToStaffDetail(staff.id, staff.name, staff.assignments),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildBoardingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Boarding Tonight', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (_boardingTonight.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(child: Text('No boarding tonight', style: TextStyle(color: Colors.grey[500]))),
            ),
          )
        else
          ...(_boardingTonight.map((request) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  PhosphorIcon(PhosphorIconsDuotone.bed, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${request.dogNames.join(", ")} (${request.ownerName})', style: const TextStyle(fontSize: 14))),
                ]),
              ))),
      ],
    );
  }

  Widget _buildQuickActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Quick Actions', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ActionChip(
              avatar: PhosphorIcon(PhosphorIconsDuotone.uploadSimple, size: 18),
              label: const Text('Upload to Feed'),
              onPressed: _uploadMediaFromDashboard,
            ),
          ],
        ),
      ],
    );
  }
}

class _StaffSummary {
  final int id;
  final String name;
  int dogCount;
  final List<DailyDogAssignment> assignments;
  _StaffSummary(this.id, this.name) : dogCount = 0, assignments = [];
}
