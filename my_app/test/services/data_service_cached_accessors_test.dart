import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  setUp(() {
    // ApiDataService reads the auth token (and the active account id) from
    // secure storage on every call, which has no implementation in a unit test.
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'test-token'});
    return CacheService().clearAll();
  });

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

  group('network fallbacks', () {
    test('getTodayAssignments falls back to the saved day when offline',
        () async {
      final date = DateTime.now();
      await CacheService().cacheAssignments(date, [assignmentJson]);

      final assignments = await HttpOverrides.runZoned(
        () => ApiDataService().getTodayAssignments(date: date),
        createHttpClient: (_) => throw const SocketException('offline'),
      );
      expect(assignments.single.dogName, 'Buddy');
    });

    test('getTodayAssignments rethrows on a cold cache', () async {
      expect(
        () => HttpOverrides.runZoned(
          () => ApiDataService().getTodayAssignments(date: DateTime.now()),
          createHttpClient: (_) => throw const SocketException('offline'),
        ),
        throwsA(anything),
      );
    });

    test('getTodayAssignments does NOT serve cache after a server error',
        () async {
      // The dashboard infers staleness from ConnectivityStatus, which a
      // *completed* request marks online. Falling back here would hide the
      // "saved data" banner and show a driver an hours-old route as if live.
      // The test binding answers every request with a 400, i.e. a reachable
      // server that refused — exactly the case that must not fall back.
      final date = DateTime.now();
      await CacheService().cacheAssignments(date, [assignmentJson]);

      expect(
        () => ApiDataService().getTodayAssignments(date: date),
        throwsA(anything),
      );
    });
  });

  group('cached profile is not shared across accounts', () {
    // The Hive cache is global, not keyed by user. If a profile fetch fails
    // right after adding a second account, serving the cached profile would
    // show the new session the previous customer's identity — and then
    // upsertActiveAccount would file the new token under the old user.
    test('getProfile refuses a cached profile belonging to another account',
        () async {
      await CacheService().cacheProfile({
        'user_id': 1,
        'username': 'alice',
        'email': 'alice@example.com',
        'is_staff': false,
      });
      FlutterSecureStorage.setMockInitialValues({'auth_token': 't', 'active_account_id': '2'});

      expect(
        () => HttpOverrides.runZoned(
          () => ApiDataService().getProfile(),
          createHttpClient: (_) => throw const SocketException('offline'),
        ),
        throwsA(anything),
      );
    });

    test('getProfile serves the cached profile for the matching account',
        () async {
      await CacheService().cacheProfile({
        'user_id': 1,
        'username': 'alice',
        'email': 'alice@example.com',
        'is_staff': false,
      });
      FlutterSecureStorage.setMockInitialValues({'auth_token': 't', 'active_account_id': '1'});

      final profile = await HttpOverrides.runZoned(
        () => ApiDataService().getProfile(),
        createHttpClient: (_) => throw const SocketException('offline'),
      );
      expect(profile.username, 'alice');
    });
  });
}
