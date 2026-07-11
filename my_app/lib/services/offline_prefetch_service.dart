import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'cache_service.dart';
import 'data_service.dart';
import 'service_locator.dart';

/// Warms the offline caches while the device still has signal, so staff who
/// load the app on WiFi before driving a route can view their dogs and route
/// with no connection at all.
///
/// What it warms:
///   - the dogs list and today's assignments (written to [CacheService] by the
///     normal [DataService] fetch paths)
///   - the photo disk cache for today's assigned dogs (the same
///     flutter_cache_manager store that CachedNetworkImage reads)
///
/// Fire-and-forget: every failure is swallowed — prefetching is best-effort
/// and must never surface errors into the UI.
class OfflinePrefetchService {
  static final OfflinePrefetchService _instance =
      OfflinePrefetchService._internal();
  factory OfflinePrefetchService() => _instance;
  OfflinePrefetchService._internal();

  /// Skip re-running when the last successful prefetch was this recent, so
  /// hooks can call [prefetchForToday] liberally (startup, app-resume).
  static const _throttle = Duration(minutes: 15);

  /// Bound the photo warm-up so an unusually busy day can't drag out the
  /// prefetch or bloat the image cache.
  static const _maxImages = 60;

  bool _running = false;

  /// Warm the dogs list, today's assignments and today's dog photos.
  Future<void> prefetchForToday() async {
    if (_running) return;
    final last = CacheService().getLastPrefetchAt();
    if (last != null && DateTime.now().difference(last) < _throttle) return;

    _running = true;
    try {
      final dataService = getIt<DataService>();
      final dogs = await dataService.getDogs();
      final assignments = await dataService.getTodayAssignments();

      // Photos for today's dogs first (the route), then their full profiles.
      final urls = <String>{
        for (final a in assignments)
          if (a.dogProfileImage != null && a.dogProfileImage!.isNotEmpty)
            a.dogProfileImage!,
        for (final a in assignments)
          for (final dog in dogs)
            if (dog.id == a.dogId.toString() &&
                dog.profileImageUrl != null &&
                dog.profileImageUrl!.isNotEmpty)
              dog.profileImageUrl!,
      };
      for (final url in urls.take(_maxImages)) {
        try {
          await DefaultCacheManager().getSingleFile(url);
        } catch (_) {
          // One missing photo mustn't stop the rest of the warm-up.
        }
      }
      await CacheService().recordPrefetchCompleted();
    } catch (e) {
      if (kDebugMode) debugPrint('[prefetch] skipped: $e');
    } finally {
      _running = false;
    }
  }
}
