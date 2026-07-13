import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';

void main() {
  // Blocks real network access (all HTTP returns 400), so fallback paths are
  // exercised deterministically.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  const dogJson = {
    'id': 7,
    'name': 'Buddy',
    'owner': 3,
    'profile_image': 'https://example.com/buddy.jpg',
    'medical_notes': 'Allergic to chicken',
    'food_instructions': 'Two scoops, morning only',
    'registered_vet': 'Marlow Vets',
    'address': '1 High Street',
    'general_notes': 'Pulls on the lead',
  };

  final assignmentJson = {
    'id': 42,
    'dog': 7,
    'dog_name': 'Buddy',
    'staff_member': 5,
    'staff_member_name': 'Sam',
    'owner_name': 'Alex',
    'date': '2026-07-10',
    'status': 'ASSIGNED',
  };

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('cached_accessors');
    Hive.init(tempDir.path);
    final box = await Hive.openBox('test_cached_accessors');
    CacheService().initWithBox(box);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() => CacheService().clearAll());

  group('synchronous cache accessors', () {
    test('all return null on a cold cache', () {
      final service = ApiDataService();
      expect(service.cachedDogs(), isNull);
      expect(service.cachedDogById('7'), isNull);
      expect(service.cachedTodayAssignments(DateTime.now()), isNull);
    });

    test('cachedDogById returns a fully-parsed Dog with care details', () async {
      await CacheService().cacheDogs([dogJson]);

      final entry = ApiDataService().cachedDogById('7');
      expect(entry, isNotNull);
      expect(entry!.cachedAt, isNotNull);
      final dog = entry.data;
      expect(dog.name, 'Buddy');
      expect(dog.medicalNotes, 'Allergic to chicken');
      expect(dog.foodInstructions, 'Two scoops, morning only');
      expect(dog.registeredVet, 'Marlow Vets');
      expect(dog.generalNotes, 'Pulls on the lead');
    });

    test('cachedDogById misses on an unknown id', () async {
      await CacheService().cacheDogs([dogJson]);
      expect(ApiDataService().cachedDogById('999'), isNull);
    });

    test('cachedDogs returns the parsed list', () async {
      await CacheService().cacheDogs([dogJson]);
      final entry = ApiDataService().cachedDogs();
      expect(entry!.data.single.name, 'Buddy');
    });

    test('cachedTodayAssignments parses the saved day', () async {
      // A recent date — older ones are pruned by cacheAssignments itself.
      final date = DateTime.now();
      await CacheService().cacheAssignments(date, [assignmentJson]);

      final entry = ApiDataService().cachedTodayAssignments(date);
      expect(entry, isNotNull);
      final assignment = entry!.data.single;
      expect(assignment.dogName, 'Buddy');
      expect(assignment.staffMemberName, 'Sam');
      expect(assignment.dogId, 7);
    });
  });

  group('network fallbacks (HTTP blocked by the test binding)', () {
    test('getTodayAssignments falls back to the saved day', () async {
      final date = DateTime.now();
      await CacheService().cacheAssignments(date, [assignmentJson]);

      final assignments =
          await ApiDataService().getTodayAssignments(date: date);
      expect(assignments.single.dogName, 'Buddy');
    });

    test('getTodayAssignments rethrows on a cold cache', () async {
      expect(
        () => ApiDataService().getTodayAssignments(date: DateTime.now()),
        throwsA(anything),
      );
    });
  });
}
