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
/// Endpoints and semantics are unchanged: each loader hits the same
/// [DataService] method and swallows errors silently (leaving the previous
/// value in place) exactly as before.
class DashboardCounts extends ChangeNotifier {
  DashboardCounts({
    required DataService dataService,
    required this.canViewInquiries,
    required this.canManageRequests,
  }) : _dataService = dataService;

  final DataService _dataService;

  /// Whether this user can see the website inquiry queue. Gates
  /// [reloadUnreadInquiryCount] in [refresh] exactly as the screen did.
  final bool canViewInquiries;

  /// Whether this user can manage requests (and therefore see the dog
  /// profile-change queue). Gates [reloadPendingProfileChangeCount] in
  /// [refresh].
  final bool canManageRequests;

  bool _disposed = false;

  int pendingRequestCount = 0;
  int pendingBoardingCount = 0;
  int unresolvedQueryCount = 0;
  int unreadInquiryCount = 0;
  int pendingProfileChangeCount = 0;
  int unresolvedDefectCount = 0;
  int unresolvedVehicleDefectCount = 0;
  int unspayedMalesCount = 0;
  List<UnspayedMaleSummary> unspayedMales = [];
  List<BoardingRequest> boardingTonight = [];

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// Loads every count in parallel, mirroring the screen's old
  /// `_loadDashboardData`: the same calls fired without awaiting each other,
  /// with the inquiry and profile-change loads gated behind their permissions.
  Future<void> refresh() async {
    await Future.wait([
      reloadPendingRequestCount(),
      reloadUnresolvedQueryCount(),
      if (canViewInquiries) reloadUnreadInquiryCount(),
      reloadBoardingTonight(),
      if (canManageRequests) reloadPendingProfileChangeCount(),
      reloadUnresolvedDefectCount(),
      reloadUnresolvedVehicleDefectCount(),
      reloadUnspayedMales(),
    ]);
  }

  Future<void> reloadUnspayedMales() async {
    try {
      final result = await _dataService.getUnspayedMales();
      unspayedMalesCount = result.count;
      unspayedMales = result.dogs;
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
    try {
      final dateRequests = await _dataService.getDateChangeRequests();
      final boardingRequests = await _dataService.getBoardingRequests();
      final pendingDateCount =
          dateRequests.where((r) => r.status == RequestStatus.pending).length;
      final pendingBoarding = boardingRequests
          .where((r) => r.status == BoardingRequestStatus.pending)
          .length;
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

  Future<void> reloadUnreadInquiryCount() async {
    try {
      final count = await _dataService.getUnreadInquiryCount();
      unreadInquiryCount = count;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> reloadBoardingTonight() async {
    try {
      final requests = await _dataService.getBoardingRequests();
      final today = DateTime.now();
      final tonight = DateTime(today.year, today.month, today.day);
      boardingTonight = requests
          .where((r) =>
              r.status == BoardingRequestStatus.approved &&
              !r.startDate.isAfter(tonight) &&
              r.endDate.isAfter(tonight))
          .toList();
      _safeNotify();
    } catch (_) {}
  }
}
