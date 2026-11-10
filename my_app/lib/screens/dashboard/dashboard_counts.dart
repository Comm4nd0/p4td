import 'package:flutter/foundation.dart';

import '../../models/boarding_request.dart';
import '../../models/date_change_request.dart';
import '../../services/data_service.dart';

/// Owns the dashboard's action-item counts and the "boarding tonight" list.
///
/// Extracted from [UnifiedDashboardScreen] (audit F14): the screen previously
/// held ~8 near-identical loaders, each with its own try/catch + setState. They
/// are folded here into a [ChangeNotifier] whose [refresh] kicks them off in
/// parallel (matching the original fire-and-forget behaviour) and whose
/// individual `reloadX` methods back the per-screen refreshes the screen runs
/// after returning from a detail screen.
///
/// One instance is owned by `HomeScreen` and shared with the dashboard, so
/// the badges beside the bell, the drawer and the dashboard's Action Items
/// read the same numbers: acting on something from any of them updates all
/// three. (They used to be two stores, each reloaded only by its own entry
/// point, and disagreed until the next resume.) The dashboard builds its own
/// only when it isn't handed one.
///
/// Each loader swallows errors silently, leaving the previous value in
/// place. A count clears on action, never on viewing — nothing here marks
/// anything read.
class DashboardCounts extends ChangeNotifier {
  DashboardCounts({
    required DataService dataService,
    this.isStaff = true,
    this.canViewInquiries = false,
    this.canManageRequests = false,
    this.canManageBoarding = false,
  }) : _dataService = dataService;

  final DataService _dataService;

  /// Owners have a Contact Staff count and nothing else; every other count
  /// is a staff queue the API refuses them.
  bool isStaff;

  /// Whether this user can see the website inquiry queue. Gates
  /// [reloadUnreadInquiryCount].
  bool canViewInquiries;

  /// Whether this user can manage requests (and therefore see the dog
  /// profile-change queue). Gates [reloadPendingProfileChangeCount] in
  /// [refresh].
  bool canManageRequests;

  /// Whether this user can manage boarding requests. Gates the pending
  /// boarding count — staff who can't act on requests aren't alerted.
  bool canManageBoarding;

  /// The profile's flags, which arrive after this is built and can change
  /// while the app is open (re-read on resume).
  void updatePermissions({
    required bool isStaff,
    required bool canViewInquiries,
    required bool canManageRequests,
    required bool canManageBoarding,
  }) {
    this.isStaff = isStaff;
    this.canViewInquiries = canViewInquiries;
    this.canManageRequests = canManageRequests;
    this.canManageBoarding = canManageBoarding;
  }

  bool _disposed = false;

  int pendingRequestCount = 0;
  int pendingBoardingCount = 0;
  int unresolvedQueryCount = 0;
  int unreadInquiryCount = 0;
  int pendingBookingFormCount = 0;
  int pendingProfileChangeCount = 0;
  int unresolvedDefectCount = 0;
  int unresolvedVehicleDefectCount = 0;
  int openIncidentCount = 0;
  /// Neutered status to confirm + vaccinations over a year old: one row on
  /// the dashboard, one call to the server.
  DogHealthFlags dogHealthFlags = const DogHealthFlags.empty();
  int get dogHealthCount => dogHealthFlags.count;

  /// Every approved boarding stay, so the dashboard can answer "who is
  /// boarding?" for any day on the date strip rather than only tonight —
  /// weekends included, where boarding is all there is (daycare is Mon–Fri).
  List<BoardingRequest> _approvedBoardings = [];

  /// Approved stays covering the night of [date] — i.e. the dogs sleeping here
  /// that night. A stay's end date is the day the dog goes home, so it isn't a
  /// night here (the same rule the "boarding tonight" list has always used).
  List<BoardingRequest> boardingOn(DateTime date) {
    final night = DateTime(date.year, date.month, date.day);
    return _approvedBoardings
        .where((r) => !r.startDate.isAfter(night) && r.endDate.isAfter(night))
        .toList();
  }

  List<BoardingRequest> get boardingTonight => boardingOn(DateTime.now());

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// The boarding list feeds both the pending count and the boarding
  /// section; one fetch serves whoever asks while it is in flight.
  Future<List<BoardingRequest>>? _boardingFetch;

  Future<List<BoardingRequest>> _boardingRequests() {
    return _boardingFetch ??= _dataService.getBoardingRequests().whenComplete(() {
      _boardingFetch = null;
    });
  }

  /// The counts shown beside the bell (and in the drawer): called on resume
  /// and whenever a push lands in the foreground, so a badge is never older
  /// than the last time the phone was looked at.
  Future<void> refreshInbox() async {
    await Future.wait([
      reloadUnresolvedQueryCount(),
      if (isStaff) reloadPendingRequestCount(),
      if (isStaff) reloadPendingBookingFormCount(),
      if (isStaff && canViewInquiries) reloadUnreadInquiryCount(),
    ]);
  }

  /// Loads every count in parallel: the inbox counts plus the dashboard's
  /// own rows, with the inquiry and profile-change loads gated behind their
  /// permissions. Staff only — owners get [refreshInbox].
  Future<void> refresh() async {
    if (!isStaff) return refreshInbox();
    await Future.wait([
      reloadPendingRequestCount(),
      reloadUnresolvedQueryCount(),
      reloadPendingBookingFormCount(),
      if (canViewInquiries) reloadUnreadInquiryCount(),
      reloadBoarding(),
      if (canManageRequests) reloadPendingProfileChangeCount(),
      reloadUnresolvedDefectCount(),
      reloadUnresolvedVehicleDefectCount(),
      reloadOpenIncidentCount(),
      reloadDogHealthFlags(),
    ]);
  }

  Future<void> reloadDogHealthFlags() async {
    try {
      dogHealthFlags = await _dataService.getDogHealthFlags();
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadPendingProfileChangeCount() async {
    try {
      final count = await _dataService.getPendingDogProfileChangeCount();
      pendingProfileChangeCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadPendingRequestCount() async {
    if (!isStaff) return;
    try {
      final dateRequests = await _dataService.getDateChangeRequests();
      final pendingDateCount =
          dateRequests.where((r) => r.status == RequestStatus.pending).length;
      // Pending boardings only alert staff who can act on them.
      var pendingBoarding = 0;
      if (canManageBoarding) {
        final boardingRequests = await _boardingRequests();
        // A date change the owner asked for on an approved stay waits on
        // a manager just like a new request.
        pendingBoarding = boardingRequests
            .where((r) => r.status == BoardingRequestStatus.pending || r.hasPendingChange)
            .length;
      }
      pendingRequestCount = pendingDateCount + pendingBoarding;
      pendingBoardingCount = pendingBoarding;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadUnresolvedQueryCount() async {
    try {
      final count = await _dataService.getUnresolvedQueryCount();
      unresolvedQueryCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadUnresolvedDefectCount() async {
    try {
      final count = await _dataService.getUnresolvedFacilityDefectCount();
      unresolvedDefectCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadUnresolvedVehicleDefectCount() async {
    try {
      final count = await _dataService.getUnresolvedVehicleDefectCount();
      unresolvedVehicleDefectCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadOpenIncidentCount() async {
    try {
      final count = await _dataService.getOpenIncidentCount();
      openIncidentCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadUnreadInquiryCount() async {
    if (!isStaff || !canViewInquiries) return;
    try {
      final count = await _dataService.getUnreadInquiryCount();
      unreadInquiryCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadPendingBookingFormCount() async {
    if (!isStaff) return;
    try {
      final count = await _dataService.getPendingIntakeRequestCount();
      pendingBookingFormCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadBoarding() async {
    try {
      final requests = await _boardingRequests();
      _approvedBoardings = requests
          .where((r) => r.status == BoardingRequestStatus.approved)
          .toList();
      _safeNotify();
    } catch (_) {}
  }
}
