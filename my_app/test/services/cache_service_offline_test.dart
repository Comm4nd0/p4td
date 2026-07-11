import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';

void main() {
  late Directory tempDir;
  late Box box;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('cache_service_offline');
    Hive.init(tempDir.path);
    box = await Hive.openBox('test_cache_offline');
    CacheService().initWithBox(box);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() => CacheService().clearAll());

  group('timestamped envelopes', () {
    test('dogs round-trip with a cachedAt close to now', () async {
      final dogs = [
        {'id': 1, 'name': 'Buddy', 'medical_notes': 'Allergic to chicken'},
      ];
      await CacheService().cacheDogs(dogs);

      final entry = CacheService().getCachedDogsEntry();
      expect(entry, isNotNull);
      expect(entry!.data, dogs);
      expect(entry.cachedAt, isNotNull);
      expect(DateTime.now().difference(entry.cachedAt!).inSeconds, lessThan(5));
      // Legacy accessor still unwraps the envelope.
      expect(CacheService().getCachedDogs(), dogs);
    });

    test('profile round-trip with a cachedAt', () async {
      await CacheService().cacheProfile({'username': 'sam', 'is_staff': true});

      final entry = CacheService().getCachedProfileEntry();
      expect(entry, isNotNull);
      expect(entry!.data['username'], 'sam');
      expect(entry.cachedAt, isNotNull);
      expect(CacheService().getCachedProfile()!['is_staff'], true);
    });

    test('a leftover legacy (pre-envelope) dogs key is invisible, not a crash', () async {
      // Old builds wrote a bare JSON list under 'dogs'; new reads use 'dogs_v2'.
      await box.put('dogs', jsonEncode([{'id': 1, 'name': 'Old'}]));
      expect(CacheService().getCachedDogs(), isNull);
      expect(CacheService().getCachedDogsEntry(), isNull);
    });
  });

  group('per-date assignments', () {
    final today = DateTime.now();
    final tomorrow = today.add(const Duration(days: 1));

    test('cache miss returns null', () {
      expect(CacheService().getCachedAssignments(today), isNull);
    });

    test('round-trips per date without collisions', () async {
      await CacheService().cacheAssignments(today, [
        {'id': 1, 'dog_name': 'Buddy'},
      ]);
      await CacheService().cacheAssignments(tomorrow, [
        {'id': 2, 'dog_name': 'Bella'},
      ]);

      final todayEntry = CacheService().getCachedAssignments(today);
      final tomorrowEntry = CacheService().getCachedAssignments(tomorrow);
      expect(todayEntry!.data.single['dog_name'], 'Buddy');
      expect(todayEntry.cachedAt, isNotNull);
      expect(tomorrowEntry!.data.single['dog_name'], 'Bella');
    });

    test('writing prunes stale date keys from earlier sessions', () async {
      // Simulate a leftover from an old session (bypasses the write-time prune).
      await box.put('assignments_2020-01-01',
          jsonEncode({'v': [], 't': '2020-01-01T08:00:00'}));

      await CacheService().cacheAssignments(today, [{'id': 1}]);

      expect(box.containsKey('assignments_2020-01-01'), isFalse);
      expect(CacheService().getCachedAssignments(today), isNotNull);
    });

    test('keeps yesterday and tomorrow, drops older than 2 days', () async {
      final yesterday = today.subtract(const Duration(days: 1));
      final lastWeek = today.subtract(const Duration(days: 7));

      await CacheService().cacheAssignments(yesterday, [{'id': 1}]);
      await CacheService().cacheAssignments(lastWeek, [{'id': 2}]);
      await CacheService().cacheAssignments(today, [{'id': 3}]);
      await CacheService().cacheAssignments(tomorrow, [{'id': 4}]);

      expect(CacheService().getCachedAssignments(yesterday), isNotNull);
      expect(CacheService().getCachedAssignments(lastWeek), isNull);
      expect(CacheService().getCachedAssignments(today), isNotNull);
      expect(CacheService().getCachedAssignments(tomorrow), isNotNull);
    });
  });

  group('prefetch bookkeeping', () {
    test('records and reads the last prefetch time', () async {
      expect(CacheService().getLastPrefetchAt(), isNull);
      await CacheService().recordPrefetchCompleted();
      final at = CacheService().getLastPrefetchAt();
      expect(at, isNotNull);
      expect(DateTime.now().difference(at!).inSeconds, lessThan(5));
    });
  });
}
