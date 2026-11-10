import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/http_client.dart' as wrapper;
import 'package:paws4thoughtdogs/services/media_limits.dart';

/// What [ApiDataService] puts on the wire and what it does with the replies,
/// against a scripted HTTP client — no server, no device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final service = ApiDataService();
  final cache = CacheService();

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('data_service_requests');
    Hive.init(tempDir.path);
    cache.initWithBox(await Hive.openBox('test_data_service_requests'));
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'test-token'});
    return cache.clearAll();
  });

  /// Runs [body] with every HTTP call answered by [handler].
  Future<T> withServer<T>(
    Future<http.Response> Function(http.Request request) handler,
    Future<T> Function() body,
  ) =>
      http.runWithClient(body, () => MockClient(handler));

  http.Response jsonReply(Object body, [int status = 200]) => http.Response(
        json.encode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  /// The dog as the server holds it — and as the edit form was opened with.
  const serverDog = {
    'id': 7,
    'name': 'Buddy',
    'owner': 3,
    'food_instructions': 'Two scoops',
    'medical_notes': 'Allergic to chicken',
    'registered_vet': 'Marlow Vets',
    'contact_number': '07000 000001',
    'emergency_contact_number': '07000 000002',
    'address': '1 High Street',
    'postcode': 'SL7 1AA',
    'access_instructions': 'Key under the pot',
    'van_placement': 'Front crate',
    'general_notes': 'Pulls on the lead',
    'daycare_days': [1, 3],
    'schedule_type': 'weekly',
    'preferred_dropoff_time': 'after_1530',
    'owner_brings_default': false,
    'owner_collects_default': false,
    'sex': 'M',
    'date_of_birth': '2022-03-04',
    'last_vaccination_date': '2026-01-10',
    'is_spayed': false,
    'daily_rate': '35.00',
    'certificate_status': 'EXPIRED',
    'certificate_needed_since': '2026-02-01',
    'cancelled_dates': ['2026-11-18'],
    'assigned_dates': ['2026-11-16', '2026-11-20'],
    'profile_image': 'https://example.com/buddy.jpg',
  };

  Dog formDog([Map<String, dynamic> overrides = const {}]) =>
      Dog.fromJson({...serverDog, ...overrides});

  /// Saves exactly what the edit screen sends when nothing was touched,
  /// with [edit] applied on top.
  Future<Dog> saveForm(
    Dog dog, {
    String? name,
    String? foodInstructions,
    String? address,
    List<Weekday>? days,
    ScheduleType? scheduleType,
    bool? ownerBringsDefault,
    bool? isSpayed,
    DateTime? dateOfBirth,
    bool clearDateOfBirth = false,
    double? dailyRate,
    Uint8List? imageBytes,
  }) =>
      service.updateDog(
        dog,
        name: name ?? dog.name,
        foodInstructions: foodInstructions ?? dog.foodInstructions ?? '',
        medicalNotes: dog.medicalNotes ?? '',
        registeredVet: dog.registeredVet ?? '',
        contactNumber: dog.contactNumber ?? '',
        emergencyContactNumber: dog.emergencyContactNumber ?? '',
        address: address ?? dog.address ?? '',
        postcode: dog.postcode ?? '',
        accessInstructions: dog.accessInstructions ?? '',
        vanPlacement: dog.vanPlacement ?? '',
        generalNotes: dog.generalNotes ?? '',
        daysInDaycare: days ?? dog.daysInDaycare,
        preferredDropoffTime: dog.preferredDropoffTime,
        scheduleType: scheduleType ?? dog.scheduleType,
        ownerBringsDefault: ownerBringsDefault ?? dog.ownerBringsDefault,
        ownerCollectsDefault: dog.ownerCollectsDefault,
        ownerBringsDefaultTime: dog.ownerBringsDefaultTime,
        ownerCollectsDefaultTime: dog.ownerCollectsDefaultTime,
        sex: dog.sex,
        dateOfBirth: clearDateOfBirth ? null : (dateOfBirth ?? dog.dateOfBirth),
        clearDateOfBirth: clearDateOfBirth,
        lastVaccinationDate: dog.lastVaccinationDate,
        isSpayed: isSpayed ?? dog.isSpayed,
        dailyRate: dailyRate ?? dog.dailyRate,
        imageBytes: imageBytes,
        imageName: imageBytes == null ? null : 'buddy.jpg',
      );

  group('updateDog sends only what changed', () {
    late http.Request sent;
    Future<http.Response> capture(http.Request request) async {
      sent = request;
      return jsonReply(serverDog);
    }

    test('an untouched form sends nothing', () async {
      await withServer(capture, () => saveForm(formDog()));

      expect(sent.method, 'PATCH');
      expect(sent.url.path, '/api/dogs/7/');
      expect(json.decode(sent.body), isEmpty);
    });

    test('one edited field is the only field sent', () async {
      await withServer(capture, () => saveForm(formDog(), foodInstructions: 'Three scoops'));

      expect(json.decode(sent.body), {'food_instructions': 'Three scoops'});
    });

    test('a stale form cannot put back the address or the days', () async {
      // The form was opened before the owner moved house and added Friday:
      // its copy still has the old address and Monday + Wednesday.
      final stale = formDog();

      await withServer(capture, () => saveForm(stale, name: 'Buddy Boy'));

      final body = json.decode(sent.body) as Map;
      expect(body, {'name': 'Buddy Boy'});
      expect(body.containsKey('address'), isFalse);
      expect(body.containsKey('daycare_days'), isFalse);
      expect(body.containsKey('schedule_type'), isFalse);
    });

    test('changed days and schedule are sent', () async {
      await withServer(
        capture,
        () => saveForm(
          formDog(),
          days: [Weekday.monday, Weekday.friday],
          scheduleType: ScheduleType.fortnightly,
        ),
      );

      expect(json.decode(sent.body), {
        'daycare_days': [1, 5],
        'schedule_type': 'fortnightly',
      });
    });

    test('the same days in another order are not a change', () async {
      await withServer(
          capture, () => saveForm(formDog(), days: [Weekday.wednesday, Weekday.monday]));

      expect(json.decode(sent.body), isEmpty);
    });

    test('a weekend day the app cannot show survives a change of days', () async {
      final dog = formDog({'daycare_days': [1, 6]});
      expect(dog.daysInDaycare, [Weekday.monday]);

      await withServer(capture, () => saveForm(dog, days: [Weekday.tuesday]));

      expect(json.decode(sent.body), {
        'daycare_days': [2, 6],
      });
    });

    test('booleans, dates and rates are sent when they differ, cleared with null', () async {
      await withServer(
        capture,
        () => saveForm(formDog(),
            ownerBringsDefault: true, isSpayed: true, dailyRate: 40, clearDateOfBirth: true),
      );

      expect(json.decode(sent.body), {
        'owner_brings_default': true,
        'is_spayed': true,
        'daily_rate': '40.00',
        'date_of_birth': null,
      });
    });

    test('fields the form does not offer are never sent', () async {
      // An owner's form passes null for the staff-only fields.
      await withServer(
        capture,
        () => service.updateDog(formDog(), name: 'Buddy', foodInstructions: 'Two scoops'),
      );

      expect(json.decode(sent.body), isEmpty);
    });

    test('a new photo goes up with the changed fields and nothing else', () async {
      await withServer(
        capture,
        () => saveForm(formDog(),
            foodInstructions: 'Three scoops', imageBytes: Uint8List.fromList([1, 2, 3])),
      );

      expect(sent.headers['content-type'], startsWith('multipart/form-data'));
      expect(sent.headers['authorization'], 'Token test-token');
      final body = latin1.decode(sent.bodyBytes);
      expect(body, contains('name="food_instructions"'));
      expect(body, contains('Three scoops'));
      expect(body, contains('name="profile_image"; filename="buddy.jpg"'));
      expect(body, isNot(contains('name="address"')));
      expect(body, isNot(contains('name="daycare_days"')));
      expect(body, isNot(contains('name="schedule_type"')));
    });

    test('the reply is the whole dog, calendar dates included', () async {
      final updated = await withServer(capture, () => saveForm(formDog()));

      expect(updated.assignedDates, [DateTime(2026, 11, 16), DateTime(2026, 11, 20)]);
      expect(updated.cancelledDates, [DateTime(2026, 11, 18)]);
      expect(updated.certificateStatus, 'EXPIRED');
      expect(updated.dailyRate, 35);
      expect(updated.preferredDropoffTime, DropoffTime.after1530);
    });

    test('a 202 means the change is waiting for staff', () async {
      await expectLater(
        withServer(
          (_) async => jsonReply({'detail': 'Sent for approval.'}, 202),
          () => saveForm(formDog(), name: 'Bud'),
        ),
        throwsA(isA<DogUpdatePendingApprovalException>()),
      );
    });
  });

  group('every write that returns a dog returns all of it', () {
    test('createDog', () async {
      late http.Request sent;
      final dog = await withServer((request) async {
        sent = request;
        return jsonReply(serverDog, 201);
      }, () => service.createDog(name: 'Buddy', ownerId: '3', daysInDaycare: [Weekday.monday]));

      expect(json.decode(sent.body), {
        'name': 'Buddy',
        'daycare_days': [1],
        'owner': 3,
      });
      expect(dog.profileImageUrl, 'https://example.com/buddy.jpg');
      expect(dog.dailyRate, 35);
      expect(dog.assignedDates, hasLength(2));
    });

    test('assignDogToUser', () async {
      final dog = await withServer(
        (_) async => jsonReply({...serverDog, 'schedule_type': 'ad_hoc'}),
        () => service.assignDogToUser('7', owner: 3),
      );

      expect(dog.scheduleType, ScheduleType.adHoc);
      expect(dog.certificateStatus, 'EXPIRED');
      expect(dog.sex, DogSex.male);
      expect(dog.lastVaccinationDate, DateTime(2026, 1, 10));
      expect(dog.ownerBringsDefaultTime, isNull);
    });
  });

  group('the saved copy stands in only when the server cannot be reached', () {
    Future<void> seedDogs() => withServer((_) async => jsonReply([serverDog]), service.getDogs);

    test('getDogs caches what it fetched', () async {
      await seedDogs();
      expect(cache.getCachedDogs(), hasLength(1));
    });

    test('getDogs with no connection serves the saved dogs', () async {
      await seedDogs();

      final dogs = await withServer(
          (_) async => throw const SocketException('Network is unreachable'), service.getDogs);

      expect(dogs.single.name, 'Buddy');
    });

    test('getDogs after a server error throws rather than show old dogs as current', () async {
      await seedDogs();

      await expectLater(
        withServer((_) async => http.Response('<html>502</html>', 502), service.getDogs),
        throwsException,
      );
    });

    test('getDogs with a reply it cannot read throws, and keeps the good copy', () async {
      await seedDogs();

      await expectLater(
        withServer((_) async => jsonReply([{'name': 'no id'}, 5]), service.getDogs),
        throwsA(anything),
      );
      expect(cache.getCachedDogs()!.single['name'], 'Buddy');
    });

    final post = {
      'id': 1,
      'uploaded_by': 2,
      'uploaded_by_name': 'Sam',
      'media_type': 'PHOTO',
      'file': 'https://example.com/a.jpg',
      'created_at': '2026-06-01T09:30:00+01:00',
    };

    Future<void> seedFeed() => withServer(
        (_) async => jsonReply({'count': 1, 'next': null, 'previous': null, 'results': [post]}),
        () => service.getFeedPage());

    test('getFeedPage with no connection serves the saved first page', () async {
      await seedFeed();

      final page = await withServer(
          (_) async => throw const SocketException('Connection refused'),
          () => service.getFeedPage());

      expect(page.items.single.uploadedByName, 'Sam');
      expect(page.hasMore, isFalse);
    });

    test('getFeedPage after a server error throws', () async {
      await seedFeed();

      await expectLater(
        withServer((_) async => http.Response('boom', 500), () => service.getFeedPage()),
        throwsException,
      );
    });
  });

  group('a fetch that outlives its session is not cached', () {
    test('dogs fetched for one account are dropped after an account switch', () async {
      final release = Completer<void>();
      final fetch = withServer((_) async {
        await release.future;
        return jsonReply([serverDog]);
      }, service.getDogs);

      // The account changes while the request is still in the air.
      await cache.clearAll();
      release.complete();
      await fetch;

      expect(cache.getCachedDogs(), isNull);
    });

    test('a fetch within the same session is cached as before', () async {
      await withServer((_) async => jsonReply([serverDog]), service.getDogs);

      expect(cache.getCachedDogs(), isNotNull);
    });
  });

  group('badge counts never invent a zero', () {
    final counts = <String, Future<int> Function()>{
      'getUnresolvedQueryCount': service.getUnresolvedQueryCount,
      'getUnreadInquiryCount': service.getUnreadInquiryCount,
      'getPendingIntakeRequestCount': service.getPendingIntakeRequestCount,
      'getPendingDogProfileChangeCount': service.getPendingDogProfileChangeCount,
      'getUnresolvedVehicleDefectCount': service.getUnresolvedVehicleDefectCount,
      'getUnresolvedFacilityDefectCount': service.getUnresolvedFacilityDefectCount,
      'getOpenIncidentCount': service.getOpenIncidentCount,
    };

    for (final entry in counts.entries) {
      test('${entry.key} returns the count, and throws when the server fails', () async {
        expect(await withServer((_) async => jsonReply({'count': 4}), entry.value), 4);
        await expectLater(
          withServer((_) async => http.Response('boom', 500), entry.value),
          throwsException,
        );
        await expectLater(
          withServer((_) async => jsonReply({'detail': 'nope'}), entry.value),
          throwsException,
        );
      });
    }
  });

  group('a 401 names the token that was rejected', () {
    test('a signed-in request reports its own token', () async {
      final rejected = <String?>[];
      wrapper.onUnauthorized = rejected.add;
      addTearDown(() => wrapper.onUnauthorized = null);

      await expectLater(
        withServer((_) async => jsonReply({'detail': 'Invalid token.'}, 401),
            service.getDogHealthFlags),
        throwsException,
      );

      expect(rejected, ['test-token']);
    });

    test('a signed-out request reports no token, so nobody is signed out for it', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final rejected = <String?>[];
      wrapper.onUnauthorized = rejected.add;
      addTearDown(() => wrapper.onUnauthorized = null);

      await expectLater(
        withServer((_) async => jsonReply({'detail': 'Not authenticated.'}, 401),
            service.getDogHealthFlags),
        throwsException,
      );

      expect(rejected, [null]);
    });
  });

  group('uploads', () {
    test('a photo over the limit is refused before anything is sent', () async {
      var requests = 0;
      await expectLater(
        withServer((_) async {
          requests++;
          return jsonReply({}, 201);
        },
            () => service.uploadGroupMedia(
                  fileBytes: Uint8List(MediaLimits.maxImageBytes + 1),
                  fileName: 'huge.jpg',
                  isVideo: false,
                )),
        throwsA(isA<MediaTooLargeException>()),
      );
      expect(requests, 0);
    });

    test('a video is streamed from its path, with the token and fields', () async {
      final file = File('${tempDir.path}/clip.mp4');
      await file.writeAsBytes(List<int>.filled(200 * 1024, 9));
      late http.Request sent;

      await withServer((request) async {
        sent = request;
        return jsonReply({}, 201);
      },
          () => service.uploadGroupMedia(
                fileBytes: Uint8List(0),
                fileName: 'clip.mp4',
                isVideo: true,
                caption: 'Zoomies',
                filePath: file.path,
              ));

      expect(sent.headers['authorization'], 'Token test-token');
      expect(sent.bodyBytes.length, greaterThan(200 * 1024));
      final head = latin1.decode(sent.bodyBytes.sublist(0, 600));
      expect(head, contains('VIDEO'));
      expect(head, contains('Zoomies'));
    });

    test('a signed-out upload sends no Authorization header at all', () async {
      FlutterSecureStorage.setMockInitialValues({});
      late http.Request sent;

      await withServer((request) async {
        sent = request;
        return jsonReply({'username': 'a', 'email': 'a@example.com'});
      }, () => service.uploadProfilePhoto(Uint8List.fromList([1, 2, 3]), 'me.jpg'));

      expect(sent.headers.containsKey('authorization'), isFalse);
    });
  });
}
