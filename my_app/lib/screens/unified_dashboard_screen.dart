import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../constants/app_colors.dart';
import '../models/closure_day.dart';
import '../models/daily_dog_assignment.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../services/media_upload_flow.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/dashboard_widgets.dart';
import '../widgets/skeleton_loaders.dart';
import 'all_dogs_today_screen.dart';
import 'pickup_map_screen.dart';
import 'staff_dog_detail_screen.dart';
import 'staff_notifications_screen.dart';
import 'boarding_request_list_screen.dart';
import 'query_list_screen.dart';
import 'inquiry_list_screen.dart';
import 'dog_profile_changes_screen.dart';
import 'facility_defects_screen.dart';
import 'fleet_screen.dart';
import 'staff_permissions_screen.dart';

class UnifiedDashboardScreen extends StatefulWidget {
  final bool canAssignDogs;
  final bool canManageRequests;
  final bool canReplyQueries;
  final bool canViewInquiries;
  final bool canAddFeedMedia;
  final bool canManageVehicles;
  final bool isStaff;
  final bool isSuperuser;
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
    this.canManageVehicles = false,
    this.isStaff = false,
    this.isSuperuser = false,
    this.myUserId,
    this.initialStaffId,
    this.onSwitchToFeed,
  });

  @override
  State<UnifiedDashboardScreen> createState() => UnifiedDashboardScreenState();
}

class UnifiedDashboardScreenState extends State<UnifiedDashboardScreen> {
  final DataService _dataService = getIt<DataService>();

  // Per-day cache. One [DayData] per day holds that day's assignments,
  // unassigned dogs, compatibility conflicts, closure, loading and error state,
  // so a day loads and invalidates as a single unit (see [_loadDay]).
  final Map<DateTime, DayData> _dayCache = {};

  // Date navigation
  List<DateTime> _dateOptions = [];
  final ScrollController _dateScrollController = ScrollController();
  late DateTime _selectedDate;

  // Closure days for the whole visible date range. This batch-loaded map is the
  // source of truth that drives the date strip and the reduced-capacity banner;
  // each [DayData.closure] is a per-day copy taken from it.
  Map<DateTime, ClosureDay> _closureDays = {};

  // Staff
  List<Map<String, dynamic>> _staffMembers = [];
  Set<int> _availableStaffIds = {};

  // Unassigned banner expansion state
  bool _unassignedExpanded = false;

  // Swipe direction for slide animation: 1 = forward (next), -1 = backward (prev)
  int _swipeDirection = 1;

  // Dashboard data
  int _pendingRequestCount = 0;
  int _pendingBoardingCount = 0;
  int _unresolvedQueryCount = 0;
  int _unreadInquiryCount = 0;
  int _pendingProfileChangeCount = 0;
  int _unresolvedDefectCount = 0;
  int _unresolvedVehicleDefectCount = 0;
  int _unspayedMalesCount = 0;
  List<UnspayedMaleSummary> _unspayedMales = [];
  List<BoardingRequest> _boardingTonight = [];

  @override
  void initState() {
    super.initState();
    _dateOptions = _generateWeekdays(DateTime.now());
    final today = DateTime.now();
    final todayIndex = _dateOptions.indexWhere((d) => _isSameDay(d, today));
    _selectedDate = _dateOptions[todayIndex >= 0 ? todayIndex : 0];
    _loadStaffMembers();
    _loadDay(_selectedDate);
    _loadClosureDays();
    _loadDashboardData();
    // Today now sits mid-strip (past weekdays precede it), so scroll it into
    // view once the list is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final idx = _dateOptions.indexWhere((d) => _isSameDay(d, _selectedDate));
      if (idx >= 0) _scrollToDateChip(idx);
    });
  }

  @override
  void dispose() {
    _dateScrollController.dispose();
    super.dispose();
  }

  // ─── Date generation ──────────────────────────────────────────────

  List<DateTime> _generateWeekdays(DateTime centerDate) {
    // Build the strip with a handful of past weekdays (so staff can scroll back
    // to review earlier days) through to a couple of weeks ahead. Weekends are
    // skipped — daycare runs Mon–Fri.
    const pastWeekdays = 5;   // ~1 working week back
    const totalWeekdays = 20; // overall strip length

    var anchor = DateTime(centerDate.year, centerDate.month, centerDate.day);
    // Snap a weekend anchor forward to Monday so "today" lands on a weekday.
    if (anchor.weekday == DateTime.saturday) {
      anchor = anchor.add(const Duration(days: 2));
    } else if (anchor.weekday == DateTime.sunday) {
      anchor = anchor.add(const Duration(days: 1));
    }

    // Walk back from the anchor to find the start, counting weekdays only.
    var start = anchor;
    var stepped = 0;
    while (stepped < pastWeekdays) {
      start = start.subtract(const Duration(days: 1));
      if (start.weekday >= DateTime.monday && start.weekday <= DateTime.friday) {
        stepped++;
      }
    }

    final List<DateTime> weekdays = [];
    var current = start;
    while (weekdays.length < totalWeekdays) {
      if (current.weekday >= DateTime.monday && current.weekday <= DateTime.friday) {
        weekdays.add(current);
      }
      current = current.add(const Duration(days: 1));
    }
    return weekdays;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Normalises a date to a date-only [DateTime] used to key [_dayCache] and
  /// [_closureDays].
  DateTime _dayKey(DateTime date) => DateTime(date.year, date.month, date.day);

  /// The cached [DayData] for [date], or an empty placeholder if not loaded.
  DayData _dayData(DateTime date) => _dayCache[_dayKey(date)] ?? const DayData();

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
            _loadDay(_selectedDate);
          }
        });
      }
    } catch (_) {}
  }

  /// Loads everything the dashboard shows for [date] — assignments, unassigned
  /// dogs and compatibility conflicts — into a single [DayData] entry, together
  /// with its loading/error state. This is the one place that populates the
  /// per-day cache.
  ///
  /// Skips work if the day is already loaded unless [force] is set. The
  /// unassigned-dog and conflict fetches run alongside the assignment fetch and
  /// fold their results into the same [DayData].
  Future<void> _loadDay(DateTime date, {bool force = false, bool prefetchAdjacent = true}) async {
    if (!mounted) return;
    final key = _dayKey(date);
    final existing = _dayCache[key];
    if (!force && existing != null && existing.loaded) return;

    final closure = _closureDays[key];
    setState(() {
      _dayCache[key] = (existing ?? const DayData())
          .copyWith(loading: true, clearError: true, closure: closure, clearClosure: closure == null);
    });

    // Assignments — drives the loading/error state shown by the day view.
    try {
      final assignments = await _dataService.getTodayAssignments(date: date);
      if (mounted) {
        setState(() {
          _dayCache[key] = _dayData(date)
              .copyWith(assignments: assignments, loading: false, loaded: true, clearError: true);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _dayCache[key] = _dayData(date).copyWith(loading: false, loaded: true, error: e);
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load assignments: $e')));
      }
    }

    // Unassigned dogs + conflicts fold into the same DayData; they don't gate
    // the loading flag (the day view renders once assignments arrive).
    _loadUnassignedDogs(date);
    _loadConflicts(date);

    // Pre-cache adjacent dates so swiping is instant.
    if (prefetchAdjacent) _prefetchAdjacentDates(date);
  }

  /// Silently loads the dates either side of [date] so the next swipe
  /// already has data and avoids the skeleton-loader artifact.
  void _prefetchAdjacentDates(DateTime date) {
    final currentIndex = _dateOptions.indexWhere((d) => _isSameDay(d, date));
    if (currentIndex < 0) return;
    if (currentIndex > 0) {
      _loadDay(_dateOptions[currentIndex - 1], prefetchAdjacent: false);
      _loadAvailableStaff(_dateOptions[currentIndex - 1]);
    }
    if (currentIndex < _dateOptions.length - 1) {
      _loadDay(_dateOptions[currentIndex + 1], prefetchAdjacent: false);
      _loadAvailableStaff(_dateOptions[currentIndex + 1]);
    }
  }

  Future<void> _loadConflicts(DateTime date) async {
    try {
      final conflicts = await _dataService.getCompatibilityConflicts(date: date);
      if (mounted) {
        setState(() => _dayCache[_dayKey(date)] = _dayData(date).copyWith(conflicts: conflicts));
      }
    } catch (_) {}
  }

  Future<void> _loadUnassignedDogs(DateTime date) async {
    try {
      final unassigned = await _dataService.getUnassignedDogs(date: date);
      if (mounted) {
        setState(() => _dayCache[_dayKey(date)] = _dayData(date).copyWith(unassignedDogs: unassigned));
      }
    } catch (_) {}
  }

  /// Single invalidation path: drop all cached days and reload the selected one.
  Future<void> _reloadSelectedDay() {
    _dayCache.clear();
    return _loadDay(_selectedDate, force: true);
  }

  Future<void> _loadDashboardData() async {
    _loadPendingRequestCount();
    _loadUnresolvedQueryCount();
    if (widget.canViewInquiries) _loadUnreadInquiryCount();
    _loadBoardingTonight();
    if (widget.canManageRequests) _loadPendingProfileChangeCount();
    _loadUnresolvedDefectCount();
    _loadUnresolvedVehicleDefectCount();
    _loadUnspayedMales();
  }

  Future<void> _loadUnspayedMales() async {
    try {
      final result = await _dataService.getUnspayedMales();
      if (mounted) {
        setState(() {
          _unspayedMalesCount = result.count;
          _unspayedMales = result.dogs;
        });
      }
    } catch (_) {}
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
      if (mounted) {
        setState(() {
          _pendingRequestCount = pendingDateCount + pendingBoardingCount;
          _pendingBoardingCount = pendingBoardingCount;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadUnresolvedQueryCount() async {
    try {
      final count = await _dataService.getUnresolvedQueryCount();
      if (mounted) setState(() => _unresolvedQueryCount = count);
    } catch (_) {}
  }

  Future<void> _loadUnresolvedDefectCount() async {
    try {
      final count = await _dataService.getUnresolvedFacilityDefectCount();
      if (mounted) setState(() => _unresolvedDefectCount = count);
    } catch (_) {}
  }

  Future<void> _loadUnresolvedVehicleDefectCount() async {
    try {
      final count = await _dataService.getUnresolvedVehicleDefectCount();
      if (mounted) setState(() => _unresolvedVehicleDefectCount = count);
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

  // ─── Public methods for parent ─────────────────────────────────────

  void filterByStaff(int? staffId) {
    if (staffId != null) {
      final assignments = _dayData(_selectedDate).assignments;
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
      // Staff can look back over the past year to review history, and manage the
      // daycare calendar years into the future.
      firstDate: DateTime(DateTime.now().year - 1, DateTime.now().month, DateTime.now().day),
      lastDate: DateTime(DateTime.now().year + 5, DateTime.now().month, DateTime.now().day),
      selectableDayPredicate: (date) =>
          date.weekday >= DateTime.monday && date.weekday <= DateTime.friday,
    );
    if (picked == null) return;

    // Check if picked date is within current date options
    final existingIndex = _dateOptions.indexWhere((d) => _isSameDay(d, picked));
    if (existingIndex >= 0) {
      final oldIndex = _dateOptions.indexWhere((d) => _isSameDay(d, _selectedDate));
      setState(() {
        _swipeDirection = existingIndex >= oldIndex ? 1 : -1;
        _selectedDate = picked;
      });
      _scrollToDateChip(existingIndex);
      _loadDay(picked);
      _loadAvailableStaff(picked);
    } else {
      // Regenerate date options centered on picked date
      setState(() {
        _swipeDirection = picked.isAfter(_selectedDate) ? 1 : -1;
        _dateOptions = _generateWeekdays(picked);
        _selectedDate = picked;
      });
      final newIndex = _dateOptions.indexWhere((d) => _isSameDay(d, picked));
      if (newIndex >= 0) _scrollToDateChip(newIndex);
      _loadDay(picked);
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
      await _loadDay(_selectedDate, force: true);
    }
  }

  Future<void> _navigateToMap(
    List<DailyDogAssignment> assignments,
    List<Dog> unassignedDogs,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PickupMapScreen(
          date: _selectedDate,
          assignments: assignments,
          unassignedDogs: unassignedDogs,
          staffMembers: _staffMembers,
          availableStaffIds: _availableStaffIds,
          canAssignDogs: widget.canAssignDogs,
        ),
      ),
    );
    if (mounted) {
      await _loadDay(_selectedDate, force: true);
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
      await _loadDay(_selectedDate, force: true);
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
                      : CircleAvatar(child: Picon(PiconsDuotone.pawPrint)),
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
            SnackBar(content: Text('Already assigned: $names'), backgroundColor: AppColors.warning, duration: const Duration(seconds: 4)),
          );
        }
        await _reloadSelectedDay();
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
            decoration: const InputDecoration(labelText: 'Assign to'),
            items: _staffMembers.map((s) {
              final name = (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
                  ? s['first_name'].toString() : s['username'].toString();
              final staffId = s['id'] as int;
              final isAvailable = _availableStaffIds.isEmpty || _availableStaffIds.contains(staffId);
              return DropdownMenuItem<int>(
                value: staffId,
                child: Row(children: [
                  Picon(PiconsDuotone.circle, size: 10, color: isAvailable ? AppColors.success : AppColors.grey400),
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
                  decoration: const InputDecoration(labelText: 'From staff'),
                  value: fromStaffId,
                  items: staffMembers.map((s) => DropdownMenuItem<int>(value: s['id'] as int, child: Text(staffLabel(s)))).toList(),
                  onChanged: (v) { setDialogState(() => fromStaffId = v); refreshPreview(setDialogState); },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'To staff'),
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
          SnackBar(content: Text('Swapped $updated assignment(s).'), backgroundColor: AppColors.success),
        );
      }
      await _reloadSelectedDay();
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
                        decoration: const InputDecoration(labelText: 'Assign to staff'),
                        value: selectedStaffId,
                        items: sortedStaff.map((s) {
                          final name = (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
                              ? s['first_name'].toString() : s['username'].toString();
                          final staffId = s['id'] as int;
                          final isAvailable = _availableStaffIds.isEmpty || _availableStaffIds.contains(staffId);
                          return DropdownMenuItem<int>(
                            value: staffId,
                            child: Row(children: [
                              Picon(PiconsDuotone.circle, size: 10, color: isAvailable ? AppColors.success : AppColors.grey400),
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
                        prefixIcon: Picon(PiconsDuotone.magnifyingGlass),
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
                                      : CircleAvatar(child: Picon(PiconsDuotone.pawPrint)),
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
              SnackBar(content: Text('${assignResult.skipped.first.dogName} - $reason'), backgroundColor: AppColors.warning),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Dog added to day'), backgroundColor: AppColors.success),
            );
          }
        }
        await _reloadSelectedDay();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to add dog: $e')));
      }
    }

    searchController.dispose();
  }

  // ─── Upload media from dashboard ──────────────────────────────────

  Future<void> _uploadMediaFromDashboard() async {
    await MediaUploadFlow(
      context: context,
      dataService: _dataService,
      // After a feed upload the dashboard reloads assignments — tagged dogs may
      // now reflect on the day's data.
      onComplete: _reloadSelectedDay,
    ).start();
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

  // ─── Date swipe navigation ─────────────────────────────────────────

  void _goToNextDate() {
    final currentIndex = _dateOptions.indexWhere((d) => _isSameDay(d, _selectedDate));
    if (currentIndex >= 0 && currentIndex < _dateOptions.length - 1) {
      final nextDate = _dateOptions[currentIndex + 1];
      setState(() {
        _swipeDirection = 1;
        _selectedDate = nextDate;
        _unassignedExpanded = false;
      });
      _scrollToDateChip(currentIndex + 1);
      _loadDay(nextDate);
      _loadAvailableStaff(nextDate);
    }
  }

  void _goToPreviousDate() {
    final currentIndex = _dateOptions.indexWhere((d) => _isSameDay(d, _selectedDate));
    if (currentIndex > 0) {
      final prevDate = _dateOptions[currentIndex - 1];
      setState(() {
        _swipeDirection = -1;
        _selectedDate = prevDate;
        _unassignedExpanded = false;
      });
      _scrollToDateChip(currentIndex - 1);
      _loadDay(prevDate);
      _loadAvailableStaff(prevDate);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Stable string identity for the swipe AnimatedSwitcher.
    final dateKey = '${_selectedDate.year}-${_selectedDate.month}-${_selectedDate.day}';
    final day = _dayData(_selectedDate);
    final assignments = day.assignments;

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
              Picon(PiconsDuotone.warning, size: 18, color: Colors.orange[700]),
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
          child: RefreshIndicator.adaptive(
            onRefresh: () async {
              await _loadDay(_selectedDate, force: true);
              await _loadDashboardData();
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                // Date-dependent content — swipe left/right to change date
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (details) {
                    if (details.primaryVelocity == null) return;
                    if (details.primaryVelocity! < -300) {
                      _goToNextDate();
                    } else if (details.primaryVelocity! > 300) {
                      _goToPreviousDate();
                    }
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    switchInCurve: Curves.easeInOut,
                    switchOutCurve: Curves.easeInOut,
                    transitionBuilder: (child, animation) {
                      final isIncoming = child.key == ValueKey(dateKey);
                      final beginOffset = Offset(
                        isIncoming
                            ? _swipeDirection.toDouble()   // slide in from the direction of travel
                            : -_swipeDirection.toDouble(), // slide out the opposite way
                        0.0,
                      );
                      return SlideTransition(
                        position: Tween<Offset>(begin: beginOffset, end: Offset.zero)
                            .animate(animation),
                        child: child,
                      );
                    },
                    layoutBuilder: (currentChild, previousChildren) {
                      return ClipRect(
                        child: Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        ),
                      );
                    },
                    child: day.loading && !day.loaded
                        ? ListTileSkeletonList(key: const ValueKey('loading'))
                        : Column(
                            key: ValueKey(dateKey),
                            children: [
                              _buildUnassignedBanner(_selectedDate),
                              _buildCompatibilityWarning(_selectedDate),
                              _buildOverviewMetrics(assignments),
                              const SizedBox(height: 16),
                              _buildStaffCards(assignments),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                // Static content — stays in place when swiping between dates
                _buildActionItems(),
                const SizedBox(height: 16),
                _buildBoardingSection(),
                const SizedBox(height: 16),
                _buildQuickActions(),
                const SizedBox(height: 80), // space for FABs
              ],
            ),
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
                      final oldIndex = _dateOptions.indexWhere((d) => _isSameDay(d, _selectedDate));
                      setState(() {
                        _swipeDirection = index >= oldIndex ? 1 : -1;
                        _selectedDate = date;
                        _unassignedExpanded = false;
                      });
                      _scrollToDateChip(index);
                      _loadDay(date);
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
            icon: Picon(PiconsDuotone.calendarBlank),
            tooltip: 'Pick a date',
            onPressed: _showDatePicker,
          ),
        ],
      ),
    );
  }

  Widget _buildUnassignedBanner(DateTime date) {
    final dogs = _dayData(date).unassignedDogs;
    if (dogs.isEmpty) return const SizedBox.shrink();
    final count = dogs.length;
    final label = count == 1 ? '1 dog unassigned' : '$count dogs unassigned';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          // Tappable header
          Material(
            color: Colors.red.shade600,
            borderRadius: _unassignedExpanded
                ? const BorderRadius.vertical(top: Radius.circular(8))
                : BorderRadius.circular(8),
            child: InkWell(
              borderRadius: _unassignedExpanded
                  ? const BorderRadius.vertical(top: Radius.circular(8))
                  : BorderRadius.circular(8),
              onTap: () => setState(() => _unassignedExpanded = !_unassignedExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Picon(PiconsDuotone.warning, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _unassignedExpanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Picon(PiconsDuotone.caretRight, color: Colors.white, size: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Expandable dog list
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Container(
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Column(
                children: [
                  ...dogs.map((dog) => _buildUnassignedDogRow(dog)),
                  // Bulk assign button
                  if (widget.canAssignDogs || widget.isStaff)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _showAssignDogsDialog,
                          icon: Picon(PiconsDuotone.usersThree, size: 18),
                          label: const Text('Assign All...'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red.shade700,
                            side: BorderSide(color: Colors.red.shade300),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            crossFadeState: _unassignedExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildCompatibilityWarning(DateTime date) {
    final conflicts = _dayData(date).conflicts;
    if (conflicts.isEmpty) return const SizedBox.shrink();
    final label = conflicts.length == 1
        ? '1 grouping conflict'
        : '${conflicts.length} grouping conflicts';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.orange.shade600,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showCompatibilityConflictsDialog(conflicts),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Picon(PiconsDuotone.warningCircle, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Incompatible dogs assigned to the same staff',
                        style: TextStyle(color: Colors.white.withAlpha(220), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Picon(PiconsDuotone.caretRight, color: Colors.white, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showCompatibilityConflictsDialog(List<CompatibilityConflict> conflicts) {
    final byStaff = <String, List<CompatibilityConflict>>{};
    for (final c in conflicts) {
      byStaff.putIfAbsent(c.staffMemberName, () => []).add(c);
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Grouping conflicts'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These dogs are flagged as incompatible but are assigned to the same staff member. Reassign one of them or update the note.',
              ),
              const SizedBox(height: 12),
              ...byStaff.entries.map((entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.key,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        ...entry.value.map((c) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    const Picon(PiconsDuotone.pawPrint, size: 16),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${c.dogAName} + ${c.dogBName}',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ]),
                                  if (c.reasons.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 22, top: 2),
                                      child: Text(
                                        c.reasons.first,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.grey700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            )),
                      ],
                    ),
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildUnassignedDogRow(Dog dog) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // Dog avatar
          if (dog.profileImageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: CachedNetworkImage(
                imageUrl: dog.profileImageUrl!,
                width: 36, height: 36, fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  width: 36, height: 36, color: Colors.grey[200],
                  child: Picon(PiconsDuotone.pawPrint, size: 18),
                ),
                errorWidget: (context, url, error) =>
                    CircleAvatar(radius: 18, child: Picon(PiconsDuotone.pawPrint, size: 18)),
              ),
            )
          else
            CircleAvatar(radius: 18, child: Picon(PiconsDuotone.pawPrint, size: 18)),
          const SizedBox(width: 10),
          // Dog name + owner
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dog.name,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                if (dog.ownerDetails != null)
                  Text(dog.ownerDetails!.username,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
          // Quick assign actions
          if (widget.isStaff)
            _buildAssignToMeButton(dog),
          if (widget.canAssignDogs) ...[
            const SizedBox(width: 4),
            _buildAssignToStaffButton(dog),
          ],
        ],
      ),
    );
  }

  Widget _buildAssignToMeButton(Dog dog) {
    return SizedBox(
      height: 32,
      child: TextButton.icon(
        onPressed: () => _quickAssignToMe(dog),
        icon: Picon(PiconsDuotone.userPlus, size: 16, color: AppColors.primary),
        label: Text('Me', style: TextStyle(fontSize: 12, color: AppColors.primary)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _buildAssignToStaffButton(Dog dog) {
    return SizedBox(
      height: 32,
      child: TextButton.icon(
        onPressed: () => _quickAssignToStaff(dog),
        icon: Picon(PiconsDuotone.users, size: 16, color: AppColors.primaryLight),
        label: Text('Staff', style: TextStyle(fontSize: 12, color: AppColors.primaryLight)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Future<void> _quickAssignToMe(Dog dog) async {
    try {
      final result = await _dataService.assignDogsToMe([int.parse(dog.id)], date: _selectedDate);
      if (mounted) {
        if (result.hasSkipped) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name}: ${result.skipped.first.reason}'), backgroundColor: AppColors.warning),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name} assigned to you'), backgroundColor: AppColors.success),
          );
        }
      }
      await _reloadSelectedDay();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to assign: $e')));
      }
    }
  }

  Future<void> _quickAssignToStaff(Dog dog) async {
    final staffId = await _pickStaffMember();
    if (staffId == null || !mounted) return;
    try {
      final result = await _dataService.assignDogs([int.parse(dog.id)], staffId, date: _selectedDate);
      if (mounted) {
        if (result.hasSkipped) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name}: ${result.skipped.first.reason}'), backgroundColor: AppColors.warning),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name} assigned'), backgroundColor: AppColors.success),
          );
        }
      }
      await _reloadSelectedDay();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to assign: $e')));
      }
    }
  }

  Widget _buildOverviewMetrics(List<DailyDogAssignment> assignments) {
    final unassignedDogs = _dayData(_selectedDate).unassignedDogs;
    final uniqueAssignedDogs = assignments.map((a) => a.dogId).toSet().length;
    final allDogsCount = uniqueAssignedDogs + unassignedDogs.length;
    final myDogs = widget.myUserId != null
        ? assignments.where((a) => a.staffMemberId == widget.myUserId).length
        : 0;
    final boardingCount = assignments.where((a) => a.isBoarding).length;

    return Column(children: [
      Row(children: [
        Expanded(child: OverviewCard(
          compact: true,
          icon: PiconsDuotone.pawPrint,
          value: '$allDogsCount',
          label: 'All Dogs',
          color: AppColors.primary,
          onTap: () => _navigateToAllDogs(assignments, unassignedDogs),
        )),
        const SizedBox(width: 6),
        Expanded(child: OverviewCard(
          compact: true,
          icon: PiconsDuotone.user,
          value: '$myDogs',
          label: 'My Dogs',
          color: AppColors.primary,
          onTap: widget.myUserId != null ? () => filterByStaff(widget.myUserId) : null,
        )),
        const SizedBox(width: 6),
        Expanded(child: OverviewCard(
          compact: true,
          icon: PiconsDuotone.clipboardText,
          value: '${assignments.length}',
          label: 'Assigned',
          color: AppColors.info,
        )),
        const SizedBox(width: 6),
        Expanded(child: OverviewCard(
          compact: true,
          icon: PiconsDuotone.bed,
          value: '$boardingCount',
          label: 'Boarding',
          color: AppColors.primaryLight,
        )),
      ]),
      if (widget.canAssignDogs) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _navigateToMap(assignments, unassignedDogs),
            icon: const Icon(Icons.map_outlined, size: 18),
            label: const Text('View routes on map'),
          ),
        ),
      ],
    ]);
  }

  Widget _buildActionItems() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Action Items', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ActionItemTile(
          icon: PiconsDuotone.clockCountdown,
          label: 'Pending Requests',
          count: _pendingRequestCount,
          countColor: _pendingRequestCount > 0 ? Colors.red : null,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(
              builder: (_) => StaffNotificationsScreen(canManageRequests: widget.canManageRequests),
            ));
            _loadPendingRequestCount();
          },
        ),
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.chats,
          label: 'Unresolved Queries',
          count: _unresolvedQueryCount,
          countColor: _unresolvedQueryCount > 0 ? Colors.red : null,
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
            icon: PiconsDuotone.envelope,
            label: 'Unread Inquiries',
            count: _unreadInquiryCount,
            countColor: _unreadInquiryCount > 0 ? Colors.red : null,
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const InquiryListScreen()));
              _loadUnreadInquiryCount();
            },
          ),
        ],
        if (widget.canManageRequests) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PiconsDuotone.dog,
            label: 'Profile Changes',
            count: _pendingProfileChangeCount,
            countColor: _pendingProfileChangeCount > 0 ? Colors.red : null,
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const DogProfileChangesScreen()));
              _loadPendingProfileChangeCount();
            },
          ),
        ],
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.bed,
          label: 'Boarding Requests',
          count: _pendingBoardingCount,
          countColor: _pendingBoardingCount > 0 ? Colors.red : null,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const BoardingRequestListScreen()));
            _loadPendingRequestCount();
          },
        ),
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.wrench,
          label: 'Site Defects',
          count: _unresolvedDefectCount,
          countColor: _unresolvedDefectCount > 0 ? Colors.red : null,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const FacilityDefectsScreen()));
            _loadUnresolvedDefectCount();
          },
        ),
        const SizedBox(height: 4),
        ActionItemTile(
          icon: PiconsDuotone.van,
          label: 'Vehicle Defects',
          count: _unresolvedVehicleDefectCount,
          countColor: _unresolvedVehicleDefectCount > 0 ? Colors.red : null,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(
              builder: (_) => FleetScreen(canManageVehicles: widget.canManageVehicles),
            ));
            _loadUnresolvedVehicleDefectCount();
          },
        ),
        if (_unspayedMalesCount > 0) ...[
          const SizedBox(height: 4),
          ActionItemTile(
            icon: PiconsDuotone.warningCircle,
            label: 'Spay status to confirm',
            count: _unspayedMalesCount,
            countColor: _unspayedMalesCount > 0 ? Colors.red : null,
            onTap: _showUnspayedMalesDialog,
          ),
        ],
      ],
    );
  }

  void _showUnspayedMalesDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spay status to confirm'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These male dogs are over 1 year old and not yet marked as spayed/neutered. '
              'Please ask the owner whether their dog has been spayed yet.',
            ),
            const SizedBox(height: 12),
            ..._unspayedMales.map((d) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      const Picon(PiconsDuotone.dog, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(d.name)),
                    ],
                  ),
                )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
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
          final collectedCount = staff.assignments
              .where((a) => a.status == AssignmentStatus.pickedUp || a.status == AssignmentStatus.droppedOff)
              .length;
          final allCollected = staff.dogCount > 0 && collectedCount == staff.dogCount;
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
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Icon(Icons.check_circle, size: 13, color: allCollected ? AppColors.success : AppColors.grey400),
                    const SizedBox(width: 3),
                    Text('collected $collectedCount of ${staff.dogCount}',
                        style: TextStyle(fontSize: 11, color: allCollected ? AppColors.success : AppColors.grey600)),
                  ]),
                  if (hasOwnerTransport) ...[
                    const SizedBox(height: 2),
                    Row(children: [
                      const Picon(PiconsDuotone.houseLine, size: 13, color: Colors.teal),
                      const SizedBox(width: 3),
                      Text(
                        [
                          if (ownerBringsCount > 0) '$ownerBringsCount drop-off${ownerBringsCount == 1 ? '' : 's'}',
                          if (ownerCollectsCount > 0) '$ownerCollectsCount pick-up${ownerCollectsCount == 1 ? '' : 's'}',
                        ].join(', '),
                        style: const TextStyle(fontSize: 11, color: Colors.teal),
                      ),
                    ]),
                  ],
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Chip(
                    label: Text('${staff.dogCount} dog${staff.dogCount == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                    backgroundColor: AppColors.primary,
                  ),
                  const SizedBox(width: 4),
                  Picon(PiconsDuotone.caretRight),
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
                  Picon(PiconsDuotone.bed, size: 18, color: AppColors.primary),
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
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: Picon(PiconsDuotone.uploadSimple, size: 18),
              label: const Text('Upload to Feed'),
              onPressed: _uploadMediaFromDashboard,
            ),
            if (widget.canAssignDogs)
              ActionChip(
                avatar: Picon(PiconsDuotone.plusCircle, size: 18),
                label: const Text('Add Dog to Day'),
                onPressed: _showAddDogToDayDialog,
              ),
            if (widget.canAssignDogs)
              ActionChip(
                avatar: Picon(PiconsDuotone.arrowsLeftRight, size: 18),
                label: const Text('Swap Staff'),
                onPressed: _showSwapStaffDialog,
              ),
            if (widget.isSuperuser)
              ActionChip(
                avatar: Picon(PiconsDuotone.shieldStar, size: 18),
                label: const Text('Manage Staff Permissions'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StaffPermissionsScreen()),
                  );
                },
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

/// Immutable snapshot of everything the dashboard shows for a single day.
///
/// Previously the dashboard kept several parallel maps/sets (assignments,
/// unassigned dogs, compatibility conflicts) keyed by an ad-hoc 'y-m-d' string,
/// each loaded and invalidated independently. [DayData] folds them into one
/// value object owned by a single `Map<DateTime, DayData>`, so a day loads and
/// invalidates as a unit.
///
/// [closure] is a convenience copy of the day's closure (sourced from the
/// batch-loaded closure-range map) so per-day consumers don't have to reach
/// back into that map.
class DayData {
  final List<DailyDogAssignment> assignments;
  final List<Dog> unassignedDogs;
  final List<CompatibilityConflict> conflicts;
  final ClosureDay? closure;
  final bool loading;
  final Object? error;

  /// Whether the day's assignments have been fetched at least once (success or
  /// failure). Mirrors the old "is there an entry in the assignment cache?"
  /// check that gated the skeleton loader.
  final bool loaded;

  const DayData({
    this.assignments = const [],
    this.unassignedDogs = const [],
    this.conflicts = const [],
    this.closure,
    this.loading = false,
    this.error,
    this.loaded = false,
  });

  DayData copyWith({
    List<DailyDogAssignment>? assignments,
    List<Dog>? unassignedDogs,
    List<CompatibilityConflict>? conflicts,
    ClosureDay? closure,
    bool clearClosure = false,
    bool? loading,
    Object? error,
    bool clearError = false,
    bool? loaded,
  }) {
    return DayData(
      assignments: assignments ?? this.assignments,
      unassignedDogs: unassignedDogs ?? this.unassignedDogs,
      conflicts: conflicts ?? this.conflicts,
      closure: clearClosure ? null : (closure ?? this.closure),
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      loaded: loaded ?? this.loaded,
    );
  }
}
