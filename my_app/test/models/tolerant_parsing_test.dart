import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/boarding_request.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/models/group_media.dart';
import 'package:paws4thoughtdogs/models/incident.dart';
import 'package:paws4thoughtdogs/models/invoice.dart';
import 'package:paws4thoughtdogs/models/support_query.dart';

/// The app and the server ship separately, so a reply can lack a field this
/// build knows about (an older server) or carry null where a value is usual.
/// One such row must never take a whole list down with it.
void main() {
  group('Dog.fromJson', () {
    test('the bare minimum parses, with safe defaults', () {
      final dog = Dog.fromJson({'id': 7});

      expect(dog.id, '7');
      expect(dog.name, '');
      expect(dog.ownerId, '');
      expect(dog.daysInDaycare, isEmpty);
      expect(dog.scheduleType, ScheduleType.weekly);
      expect(dog.certificateStatus, 'OK'); // an older server must not start a nag
      expect(dog.alternativeAddresses, isEmpty);
      expect(dog.additionalOwners, isEmpty);
      expect(dog.assignedDates, isEmpty);
      expect(dog.dailyRate, isNull);
    });

    test('explicit nulls parse like missing fields', () {
      final dog = Dog.fromJson({
        'id': 7,
        'name': null,
        'owner': null,
        'owner_details': null,
        'additional_owners_details': null,
        'daycare_days': null,
        'alternative_addresses': null,
        'latitude': null,
        'daily_rate': null,
        'cancelled_dates': null,
        'general_notes': null,
        'van_placement': null,
      });

      expect(dog.ownerDetails, isNull);
      expect(dog.generalNotes, isNull);
      expect(dog.latitude, isNull);
    });

    test('weekdays are read by number, in any JSON spelling', () {
      final dog = Dog.fromJson({
        'id': 7,
        'daycare_days': [1, '3', 5.0, 3],
      });

      expect(dog.daysInDaycare, [Weekday.monday, Weekday.wednesday, Weekday.friday]);
      expect(dog.otherDaycareDayNumbers, isEmpty);
    });

    test('a weekend day is kept aside, not turned into Monday', () {
      final dog = Dog.fromJson({
        'id': 7,
        'daycare_days': [2, 6, 7],
      });

      expect(dog.daysInDaycare, [Weekday.tuesday]);
      expect(dog.otherDaycareDayNumbers, [6, 7]);
      expect(dog.daycareDayNumbers(dog.daysInDaycare), [2, 6, 7]);
      expect(dog.daycareDayNumbers([Weekday.monday, Weekday.thursday]), [1, 4, 6, 7]);
      expect(dog.copyWith(name: 'Rex').otherDaycareDayNumbers, [6, 7]);
    });

    test('values that are not day numbers are dropped', () {
      final dog = Dog.fromJson({
        'id': 7,
        'daycare_days': [0, 8, 'monday', null, 4],
      });

      expect(dog.daysInDaycare, [Weekday.thursday]);
      expect(dog.otherDaycareDayNumbers, isEmpty);
    });

    test('unknown fields from a newer server are ignored', () {
      final dog = Dog.fromJson({'id': 7, 'name': 'Buddy', 'favourite_toy': 'ball', 'tags': [1]});

      expect(dog.name, 'Buddy');
    });
  });

  group('DailyDogAssignment.fromJson', () {
    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
          'id': 42,
          'dog': 7,
          'dog_name': 'Buddy',
          'staff_member': 5,
          'staff_member_name': 'Sam',
          'owner_name': 'Alex',
          'date': '2026-07-10',
          'status': 'ASSIGNED',
          ...extra,
        };

    test('a row with no staff member parses as unassigned', () {
      final assignment = DailyDogAssignment.fromJson(row({
        'staff_member': null,
        'staff_member_name': null,
        'status': 'UNASSIGNED',
      }));

      expect(assignment.isUnassigned, isTrue);
      expect(assignment.staffMemberId, DailyDogAssignment.unassignedStaffId);
      expect(assignment.staffMemberName, '');
      expect(assignment.dogName, 'Buddy');
    });

    test('a row with the field missing altogether parses too', () {
      final json = row()..remove('staff_member');

      expect(DailyDogAssignment.fromJson(json).isUnassigned, isTrue);
    });

    test('a normal row keeps its staff member, as a number or a string', () {
      expect(DailyDogAssignment.fromJson(row()).staffMemberId, 5);
      expect(DailyDogAssignment.fromJson(row()).isUnassigned, isFalse);
      expect(DailyDogAssignment.fromJson(row({'staff_member': '12'})).staffMemberId, 12);
    });

    test('one driverless row does not lose the rest of the list', () {
      final list = [
        row(),
        row({'id': 43, 'staff_member': null}),
        row({'id': 44, 'staff_member': 6}),
      ].map(DailyDogAssignment.fromJson).toList();

      expect(list.map((a) => a.id), [42, 43, 44]);
    });

    test('the date stays the calendar day it says', () {
      expect(DailyDogAssignment.fromJson(row()).date, DateTime(2026, 7, 10));
    });
  });

  group('BoardingRequest.fromJson', () {
    test('only the essentials', () {
      final stay = BoardingRequest.fromJson({
        'id': 1,
        'start_date': '2026-10-24',
        'end_date': '2026-10-26',
      });

      expect(stay.ownerId, 0);
      expect(stay.ownerName, '');
      expect(stay.dogIds, isEmpty);
      expect(stay.dogNames, isEmpty);
      expect(stay.status, BoardingRequestStatus.pending);
      expect(stay.hasPendingChange, isFalse);
      expect(stay.approvedAt, isNull);
      expect(stay.requestedStartDate, isNull);
      expect(stay.changeRequestedAt, isNull);
    });

    test('nulls where values are usual', () {
      final stay = BoardingRequest.fromJson({
        'id': 1,
        'owner': null,
        'owner_name': null,
        'dogs': null,
        'dog_names': null,
        'start_date': '2026-10-24',
        'end_date': '2026-10-26',
        'status': 'SOMETHING_NEW',
        'special_instructions': null,
        'approved_at': null,
        'assigned_staff': null,
        'created_at': null,
        'has_pending_change': null,
      });

      expect(stay.dogIds, isEmpty);
      expect(stay.status, BoardingRequestStatus.pending);
      expect(stay.hasPendingChange, isFalse);
    });
  });

  group('Invoice.fromJson', () {
    test('an invoice in a dog\'s name has no customer', () {
      final invoice = Invoice.fromJson({
        'id': 3,
        'customer': null,
        'customer_details': null,
        'billed_dog': 7,
        'billed_name': 'Buddy',
        'period_year': 2026,
        'period_month': 11,
        'lines': [
          {'id': 1, 'dog': null, 'dog_name': null, 'description': 'Amended in Xero'},
        ],
      });

      expect(invoice.customerId, isNull);
      expect(invoice.customerName, 'Buddy');
      expect(invoice.customerEmail, '');
      expect(invoice.status, 'DRAFT');
      expect(invoice.total, 0);
      expect(invoice.dueDate, isNull);
      expect(invoice.sentAt, isNull);
      expect(invoice.lines.single.dogId, isNull);
      expect(invoice.lines.single.quantity, 0);
      expect(invoice.payments, isEmpty);
    });

    test('only an id', () {
      final invoice = Invoice.fromJson({'id': 3});

      expect(invoice.periodYear, 0);
      expect(invoice.customerName, '');
      expect(invoice.lines, isEmpty);
    });
  });

  group('SupportQuery.fromJson', () {
    test('a list row has no messages, dogs or timestamps of its own', () {
      final query = SupportQuery.fromJson({'id': 1});

      expect(query.ownerId, 0);
      expect(query.ownerName, '');
      expect(query.ownerDogs, isNull); // null is what an owner is sent
      expect(query.messages, isEmpty);
      expect(query.status, QueryStatus.open);
      expect(query.resolvedAt, isNull);
      expect(query.lastMessageAt, isNull);
      expect(query.staffHasUnread, isFalse);
    });
  });

  group('GroupMedia.fromJson', () {
    test('a post with nothing but an id', () {
      final post = GroupMedia.fromJson({'id': 1, 'uploaded_by': null});

      expect(post.fileUrl, '');
      expect(post.uploadedByName, '');
      expect(post.reactions, isEmpty);
      expect(post.comments, isEmpty);
      expect(post.taggedDogs, isEmpty);
      expect(post.caption, isNull);
    });

    test('reaction counts survive odd values', () {
      final post = GroupMedia.fromJson({
        'id': 1,
        'uploaded_by': 2,
        'reactions': {'❤️': 3, '🐾': 2.0, '👍': null},
        'user_reaction': null,
      });

      expect(post.reactions, {'❤️': 3, '🐾': 2});
    });
  });

  group('Incident.fromJson', () {
    test('only an id', () {
      final incident = Incident.fromJson({'id': 1});

      expect(incident.title, '');
      expect(incident.status, 'OPEN');
      expect(incident.dogsInvolved, isEmpty);
      expect(incident.media, isEmpty);
      expect(incident.comments, isEmpty);
      expect(incident.resolvedAt, isNull);
      expect(incident.reportedByName, isNull);
    });

    test('media and dogs with gaps', () {
      final incident = Incident.fromJson({
        'id': 1,
        'occurred_at': '2026-07-02T14:05:00Z',
        'media': [
          {'id': 1, 'file': null, 'thumbnail': null},
        ],
        'dogs_involved': [
          {'id': 1, 'dog': 7, 'owner_name': null},
        ],
      });

      expect(incident.media.single.fileUrl, isNull);
      expect(incident.media.single.isVideo, isFalse);
      expect(incident.dogsInvolved.single.dogId, '7');
      expect(incident.dogsInvolved.single.ownerName, isNull);
    });
  });
}
