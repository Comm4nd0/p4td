import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/api_datetime.dart';
import 'package:paws4thoughtdogs/models/boarding_request.dart';
import 'package:paws4thoughtdogs/models/comment.dart';
import 'package:paws4thoughtdogs/models/date_change_request.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/models/group_media.dart';
import 'package:paws4thoughtdogs/models/incident.dart';
import 'package:paws4thoughtdogs/models/support_query.dart';

/// Server timestamps come out of the models in local time; calendar dates
/// stay the day they say.
///
/// The assertions compare against `DateTime.utc(...)` — the same instant —
/// and check `isUtc`, so they hold whatever timezone the tests run in.
void main() {
  group('parseApiDateTime', () {
    test('a +01:00 timestamp is that instant, in local time', () {
      final parsed = parseApiDateTime('2026-06-01T09:30:00+01:00')!;

      expect(parsed.isUtc, isFalse);
      expect(parsed.isAtSameMomentAs(DateTime.utc(2026, 6, 1, 8, 30)), isTrue);
      expect(parsed.hour, DateTime.utc(2026, 6, 1, 8, 30).toLocal().hour);
    });

    test('a Z timestamp is that instant, in local time', () {
      final parsed = parseApiDateTime('2026-11-10T23:45:10.123456Z')!;

      expect(parsed.isUtc, isFalse);
      expect(parsed.isAtSameMomentAs(DateTime.utc(2026, 11, 10, 23, 45, 10, 123, 456)), isTrue);
    });

    test('the two spellings of one moment are equal', () {
      expect(
        parseApiDateTime('2026-06-01T00:30:00+01:00'),
        parseApiDateTime('2026-05-31T23:30:00Z'),
      );
    });

    test('converting again changes nothing, so older .toLocal() calls are harmless', () {
      final parsed = parseApiDateTime('2026-06-01T09:30:00+01:00')!;

      expect(parsed.toLocal(), parsed);
      expect(parsed.toLocal().hour, parsed.hour);
    });

    test('missing, empty and nonsense values are null', () {
      expect(parseApiDateTime(null), isNull);
      expect(parseApiDateTime(''), isNull);
      expect(parseApiDateTime('yesterday'), isNull);
      expect(parseApiDateTime(42), isNull);
    });

    test('requireApiDateTime never throws', () {
      expect(requireApiDateTime(null), DateTime.fromMillisecondsSinceEpoch(0));
      expect(requireApiDateTime('2026-06-01T09:30:00Z').isUtc, isFalse);
    });
  });

  group('calendar dates are not shifted', () {
    test('parseApiDate keeps the day it was given', () {
      final date = parseApiDate('2026-03-29')!; // the day UK clocks go forward

      expect((date.year, date.month, date.day), (2026, 3, 29));
      expect((date.hour, date.minute), (0, 0));
      expect(date.isUtc, isFalse);
    });

    test('a date-only string through parseApiDateTime is the same local day', () {
      expect(parseApiDateTime('2026-10-25'), DateTime(2026, 10, 25));
    });

    test('a boarding stay keeps its dates while its timestamps are local', () {
      final stay = BoardingRequest.fromJson({
        'id': 1,
        'owner': 2,
        'owner_name': 'Alex',
        'dogs': [7],
        'dog_names': ['Buddy'],
        'start_date': '2026-10-24',
        'end_date': '2026-10-26',
        'status': 'APPROVED',
        'approved_at': '2026-10-01T23:30:00Z',
        'created_at': '2026-09-30T23:30:00+01:00',
      });

      expect(stay.startDate, DateTime(2026, 10, 24));
      expect(stay.endDate, DateTime(2026, 10, 26));
      expect(stay.approvedAt!.isUtc, isFalse);
      expect(stay.approvedAt!.isAtSameMomentAs(DateTime.utc(2026, 10, 1, 23, 30)), isTrue);
      expect(stay.createdAt.isAtSameMomentAs(DateTime.utc(2026, 9, 30, 22, 30)), isTrue);
    });

    test('a date-change request keeps its days', () {
      final request = DateChangeRequest.fromJson({
        'id': 5,
        'dog': 7,
        'request_type': 'CHANGE',
        'original_date': '2026-03-30',
        'new_date': '2026-03-31',
        'status': 'PENDING',
        'created_at': '2026-03-28T23:59:00Z',
      });

      expect(request.originalDate, DateTime(2026, 3, 30));
      expect(request.newDate, DateTime(2026, 3, 31));
      expect(request.createdAt.isUtc, isFalse);
    });
  });

  group('models hand out local timestamps', () {
    test('feed post and its comments', () {
      final post = GroupMedia.fromJson({
        'id': 1,
        'uploaded_by': 2,
        'media_type': 'PHOTO',
        'file': 'https://example.com/a.jpg',
        'created_at': '2026-07-01T00:15:00+01:00',
        'comments': [
          {'id': 9, 'user': 3, 'text': 'Aww', 'created_at': '2026-07-01T07:00:00Z'},
        ],
      });

      expect(post.createdAt.isUtc, isFalse);
      expect(post.createdAt.isAtSameMomentAs(DateTime.utc(2026, 6, 30, 23, 15)), isTrue);
      expect(post.comments.single.createdAt.isUtc, isFalse);
    });

    test('support thread', () {
      final query = SupportQuery.fromJson({
        'id': 1,
        'owner': 2,
        'subject': 'Keys',
        'status': 'RESOLVED',
        'resolved_at': '2026-07-02T10:00:00Z',
        'last_message_at': '2026-07-02T09:00:00+01:00',
        'created_at': '2026-07-01T09:00:00+01:00',
        'updated_at': '2026-07-02T10:00:00Z',
      });

      for (final moment in [query.resolvedAt!, query.lastMessageAt!, query.createdAt, query.updatedAt]) {
        expect(moment.isUtc, isFalse);
      }
    });

    test('incident', () {
      final incident = Incident.fromJson({
        'id': 1,
        'occurred_at': '2026-07-02T14:05:00Z',
        'resolved_at': '2026-07-03T08:00:00+01:00',
      });

      expect(incident.occurredAt.isUtc, isFalse);
      expect(incident.occurredAt.isAtSameMomentAs(DateTime.utc(2026, 7, 2, 14, 5)), isTrue);
      expect(incident.resolvedAt!.isUtc, isFalse);
    });

    test('a comment with no timestamp still parses', () {
      final comment = Comment.fromJson({'id': 1, 'user': 2});

      expect(comment.text, '');
      expect(comment.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
    });
  });
}
