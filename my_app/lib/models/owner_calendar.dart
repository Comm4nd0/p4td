import 'package:intl/intl.dart';
import 'closure_day.dart';

/// The approved boarding stay behind a boarding day.
class CalendarBoardingStay {
  final DateTime start;
  final DateTime end;
  final int nights;

  CalendarBoardingStay({required this.start, required this.end, required this.nights});

  static CalendarBoardingStay? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final start = DateTime.tryParse(json['start'] ?? '');
    final end = DateTime.tryParse(json['end'] ?? '');
    if (start == null || end == null) return null;
    return CalendarBoardingStay(
      start: start,
      end: end,
      nights: json['nights'] is int ? json['nights'] : end.difference(start).inDays,
    );
  }

  static final DateFormat _dayMonth = DateFormat('EEE d MMM');
  static final DateFormat _day = DateFormat('EEE d');

  /// "1 night, Mon 6 – Tue 7 Oct" — the nights are what the stay is, two
  /// coloured days on a calendar read as two nights otherwise.
  String get summary {
    final nightsLabel = nights == 1 ? '1 night' : '$nights nights';
    final from = start.month == end.month ? _day.format(start) : _dayMonth.format(start);
    return '$nightsLabel, $from – ${_dayMonth.format(end)}';
  }
}

/// One of the caller's dogs attending on a given day.
class CalendarDogEntry {
  final String id;
  final String name;
  final bool boarding;

  /// Booked on a weekday that isn't one of the dog's regular days.
  final bool extra;

  /// The stay behind a boarding day; null otherwise (and from older servers).
  final CalendarBoardingStay? boardingStay;

  CalendarDogEntry({
    required this.id,
    required this.name,
    required this.boarding,
    this.extra = false,
    this.boardingStay,
  });

  factory CalendarDogEntry.fromJson(Map<String, dynamic> json) => CalendarDogEntry(
        id: json['id'].toString(),
        name: json['name'] ?? '',
        boarding: json['boarding'] == true,
        extra: json['extra'] == true,
        boardingStay: CalendarBoardingStay.fromJson(json['boarding_stay']),
      );

  /// What the dog is in for on [day], for a day panel's subtitle.
  String describe(DateTime day) {
    if (!boarding) return extra ? 'Extra day' : 'Daycare';
    final stay = boardingStay;
    if (stay == null || stay.nights < 1) return 'Boarding';
    bool same(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    if (same(day, stay.start)) return 'Arrives for boarding · ${stay.summary}';
    if (same(day, stay.end)) return 'Goes home from boarding · ${stay.summary}';
    return 'Boarding · ${stay.summary}';
  }
}

class CalendarPendingRequest {
  final int id;
  final String dogId;

  /// 'ADD_DAY' | 'CANCEL' | 'CHANGE'
  final String requestType;

  CalendarPendingRequest({required this.id, required this.dogId, required this.requestType});

  factory CalendarPendingRequest.fromJson(Map<String, dynamic> json) => CalendarPendingRequest(
        id: json['id'],
        dogId: json['dog_id'].toString(),
        requestType: json['request_type'] ?? '',
      );
}

class CalendarWaitlistEntry {
  final int id;
  final String dogId;

  /// 'WAITING' | 'NOTIFIED'
  final String status;

  CalendarWaitlistEntry({required this.id, required this.dogId, required this.status});

  factory CalendarWaitlistEntry.fromJson(Map<String, dynamic> json) => CalendarWaitlistEntry(
        id: json['id'],
        dogId: json['dog_id'].toString(),
        status: json['status'] ?? 'WAITING',
      );
}

class CalendarClosure {
  final ClosureType closureType;
  final String reason;

  CalendarClosure({required this.closureType, required this.reason});

  factory CalendarClosure.fromJson(Map<String, dynamic> json) => CalendarClosure(
        closureType: ClosureType.fromApi(json['closure_type'] ?? 'CLOSED'),
        reason: json['reason'] ?? '',
      );
}

class CalendarDay {
  final DateTime date;
  final List<CalendarDogEntry> dogs;
  final CalendarClosure? closure;
  final bool isFull;
  final int? spotsLeft;
  final int? capacity;
  final List<CalendarPendingRequest> pendingRequests;
  final List<CalendarWaitlistEntry> waitlist;

  CalendarDay({
    required this.date,
    required this.dogs,
    this.closure,
    required this.isFull,
    this.spotsLeft,
    this.capacity,
    required this.pendingRequests,
    required this.waitlist,
  });

  factory CalendarDay.fromJson(Map<String, dynamic> json) => CalendarDay(
        date: DateTime.parse(json['date']),
        dogs: ((json['dogs'] as List<dynamic>?) ?? [])
            .map((e) => CalendarDogEntry.fromJson(e))
            .toList(),
        closure: json['closure'] != null ? CalendarClosure.fromJson(json['closure']) : null,
        isFull: json['is_full'] == true,
        spotsLeft: json['spots_left'],
        capacity: json['capacity'],
        pendingRequests: ((json['pending_requests'] as List<dynamic>?) ?? [])
            .map((e) => CalendarPendingRequest.fromJson(e))
            .toList(),
        waitlist: ((json['waitlist'] as List<dynamic>?) ?? [])
            .map((e) => CalendarWaitlistEntry.fromJson(e))
            .toList(),
      );
}

class CalendarDogRef {
  final String id;
  final String name;

  CalendarDogRef({required this.id, required this.name});

  factory CalendarDogRef.fromJson(Map<String, dynamic> json) =>
      CalendarDogRef(id: json['id'].toString(), name: json['name'] ?? '');
}

class OwnerCalendar {
  final DateTime start;
  final DateTime end;
  final List<CalendarDogRef> dogs;
  final List<CalendarDay> days;

  OwnerCalendar({required this.start, required this.end, required this.dogs, required this.days});

  factory OwnerCalendar.fromJson(Map<String, dynamic> json) => OwnerCalendar(
        start: DateTime.parse(json['start']),
        end: DateTime.parse(json['end']),
        dogs: ((json['dogs'] as List<dynamic>?) ?? [])
            .map((e) => CalendarDogRef.fromJson(e))
            .toList(),
        days: ((json['days'] as List<dynamic>?) ?? [])
            .map((e) => CalendarDay.fromJson(e))
            .toList(),
      );
}

class WaitlistEntry {
  final int id;
  final String dogId;
  final String dogName;
  final DateTime date;
  final String status;

  WaitlistEntry({
    required this.id,
    required this.dogId,
    required this.dogName,
    required this.date,
    required this.status,
  });

  factory WaitlistEntry.fromJson(Map<String, dynamic> json) => WaitlistEntry(
        id: json['id'],
        dogId: json['dog'].toString(),
        dogName: json['dog_name'] ?? '',
        date: DateTime.parse(json['date']),
        status: json['status'] ?? 'WAITING',
      );
}
