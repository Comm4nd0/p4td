import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/boarding_request.dart';
import 'package:paws4thoughtdogs/models/closure_day.dart';
import 'package:paws4thoughtdogs/models/date_change_request.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/models/invoice.dart';
import 'package:paws4thoughtdogs/models/owner_calendar.dart';
import 'package:paws4thoughtdogs/models/support_query.dart';
import 'package:paws4thoughtdogs/screens/client_dashboard_screen.dart';
import 'package:paws4thoughtdogs/screens/dashboard/client_attention_section.dart';
import 'package:paws4thoughtdogs/screens/dashboard/client_billing_card.dart';
import 'package:paws4thoughtdogs/screens/dashboard/client_boarding_section.dart';
import 'package:paws4thoughtdogs/screens/dashboard/client_today_section.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

/// A Tuesday. Every date below is relative to it and the clock is pinned to
/// it, so the suite reads the same on any day it runs.
final _today = DateTime(2026, 9, 15);

const _buddy = ('7', 'Buddy');
const _luna = ('8', 'Luna');

/// Builds the calendar the API would return for [start]..[end]: one entry per
/// day, with the given dogs attending on the given days.
OwnerCalendar _calendar(
  DateTime start,
  DateTime end, {
  Map<DateTime, List<CalendarDogEntry>> attending = const {},
  Map<DateTime, CalendarClosure> closures = const {},
  Map<DateTime, List<CalendarPendingRequest>> pending = const {},
  Map<DateTime, List<CalendarWaitlistEntry>> waitlist = const {},
  Set<DateTime> full = const {},
}) {
  final days = <CalendarDay>[];
  for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
    days.add(CalendarDay(
      date: d,
      dogs: attending[d] ?? const [],
      closure: closures[d],
      isFull: full.contains(d),
      pendingRequests: pending[d] ?? const [],
      waitlist: waitlist[d] ?? const [],
    ));
  }
  return OwnerCalendar(
    start: start,
    end: end,
    dogs: [
      CalendarDogRef(id: _buddy.$1, name: _buddy.$2),
      CalendarDogRef(id: _luna.$1, name: _luna.$2),
    ],
    days: days,
  );
}

CalendarDogEntry _in((String, String) dog, {bool boarding = false}) =>
    CalendarDogEntry(id: dog.$1, name: dog.$2, boarding: boarding);

Dog _dog(
  (String, String) ref, {
  String? contact = '01234 567890',
  String? emergency = '07700 900000',
  DateTime? lastVaccination,
  bool vaccinationOverdue = false,
}) =>
    Dog(
      id: ref.$1,
      name: ref.$2,
      ownerId: '2',
      contactNumber: contact,
      emergencyContactNumber: emergency,
      lastVaccinationDate: lastVaccination,
      vaccinationOverdue: vaccinationOverdue,
    );

BoardingRequest _stay({
  required int id,
  required List<String> dogs,
  required DateTime start,
  required DateTime end,
  BoardingRequestStatus status = BoardingRequestStatus.approved,
  String? carer,
}) =>
    BoardingRequest(
      id: id,
      ownerId: 2,
      ownerName: 'Alex',
      dogIds: const [7],
      dogNames: dogs,
      startDate: start,
      endDate: end,
      status: status,
      assignedStaffName: carer,
      createdAt: DateTime(2026, 9, 1),
    );

Invoice _invoice({
  required int id,
  required int month,
  String status = 'SENT',
  double total = 280,
  double paid = 0,
  bool overdue = false,
  DateTime? due,
}) =>
    Invoice(
      id: id,
      customerName: 'Alex',
      customerEmail: 'alex@example.com',
      periodYear: 2026,
      periodMonth: month,
      periodLabel: '${const [
        '', 'January', 'February', 'March', 'April', 'May', 'June', 'July',
        'August', 'September', 'October', 'November', 'December',
      ][month]} 2026',
      status: status,
      total: total,
      amountPaid: paid,
      balance: total - paid,
      dueDate: due,
      isOverdue: overdue,
    );

SupportQuery _query({required int id, bool unread = false}) => SupportQuery(
      id: id,
      ownerId: 2,
      ownerName: 'Alex',
      subject: 'Pickup time',
      status: QueryStatus.open,
      hasUnreadReply: unread,
      createdAt: DateTime(2026, 9, 10),
      updatedAt: DateTime(2026, 9, 12),
    );

DateChangeRequest _dayRequest({required String id, RequestStatus status = RequestStatus.pending}) =>
    DateChangeRequest(
      id: id,
      dogId: '7',
      dogName: 'Buddy',
      ownerName: 'Alex',
      requestType: RequestType.addDay,
      newDate: DateTime(2026, 9, 22),
      status: status,
      isCharged: false,
      createdAt: DateTime(2026, 9, 10),
    );

class _FakeDataService extends MockDataService {
  final OwnerCalendar Function(DateTime start, DateTime end) calendarFor;
  final List<BoardingRequest> boarding;
  final List<Invoice> invoices;
  final List<SupportQuery> queries;
  final List<ClosureDay> closures;
  final bool failBoarding;
  final bool failCalendar;

  _FakeDataService({
    required this.calendarFor,
    this.boarding = const [],
    this.invoices = const [],
    this.queries = const [],
    this.closures = const [],
    this.failBoarding = false,
    this.failCalendar = false,
  });

  @override
  Future<OwnerCalendar> getOwnerCalendar({DateTime? start, DateTime? end}) async {
    if (failCalendar) throw Exception('server error');
    return calendarFor(start!, end!);
  }

  @override
  Future<List<BoardingRequest>> getBoardingRequests() async {
    if (failBoarding) throw Exception('server error');
    return boarding;
  }

  @override
  Future<List<Invoice>> getInvoices({int? year, int? month, String? status, int? customerId}) async =>
      invoices;

  @override
  Future<List<SupportQuery>> getSupportQueries() async => queries;

  @override
  Future<List<ClosureDay>> getClosureDays({DateTime? fromDate, DateTime? toDate}) async => closures;
}

Future<void> _pump(WidgetTester tester, DataService fake, {List<Dog> dogs = const []}) async {
  if (getIt.isRegistered<DataService>()) {
    getIt.unregister<DataService>();
  }
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());

  // Tall enough for every section to build: the dashboard is a lazy list
  // and the Calendar card alone fills most of a phone screen.
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: ClientDashboardScreen(now: _today, dogs: dogs)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// The dashboard is a lazily built list; sections near the bottom don't
/// exist until scrolled into the test viewport.
Future<void> _scrollToBottom(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -4000));
  await tester.pump();
}

void main() {
  group('today & next visit', () {
    testWidgets('each dog shows where it is today and when it is next in',
        (tester) async {
      final thursday = _today.add(const Duration(days: 2));
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e, attending: {
            _today: [_in(_buddy)],
            thursday: [_in(_buddy)],
          }),
        ),
      );

      expect(find.text('Tue 15/09/26'), findsOneWidget);
      final todaySection = find.byType(ClientTodaySection);
      expect(find.descendant(of: todaySection, matching: find.text('Buddy')), findsOneWidget);
      expect(find.text('In daycare today'), findsOneWidget);
      expect(find.text('Next in: Thu 17/09/26'), findsOneWidget);
      expect(find.descendant(of: todaySection, matching: find.text('Luna')), findsOneWidget);
      expect(find.text('At home today'), findsOneWidget);
      // The calendar was asked for today plus the dashboard's horizon.
      expect(find.text('Nothing booked in the next 60 days'), findsOneWidget);
    });

    testWidgets('a boarding day today and a pending request are both named',
        (tester) async {
      final monday = _today.add(const Duration(days: 6));
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e, attending: {
            _today: [_in(_luna, boarding: true)],
            monday: [_in(_buddy, boarding: true)],
          }, pending: {
            // One CHANGE request listed on both of its dates counts once.
            monday: [CalendarPendingRequest(id: 41, dogId: '7', requestType: 'CHANGE')],
            monday.add(const Duration(days: 1)): [
              CalendarPendingRequest(id: 41, dogId: '7', requestType: 'CHANGE'),
            ],
          }),
        ),
      );

      expect(find.text('Boarding with us'), findsOneWidget);
      expect(find.text('Next in: Mon 21/09/26 (boarding)'), findsOneWidget);
      expect(find.text('1 request awaiting approval'), findsOneWidget);
    });

    testWidgets('a closure today is flagged above the dogs', (tester) async {
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e, closures: {
            _today: CalendarClosure(closureType: ClosureType.closed, reason: 'Bank holiday'),
          }),
        ),
      );

      expect(find.text('Closed today'), findsOneWidget);
      expect(find.descendant(of: find.byType(ClientTodaySection), matching: find.text('Bank holiday')), findsOneWidget);
    });

    testWidgets('a weekend reads as home for the weekend, not "at home today"',
        (tester) async {
      final saturday = DateTime(2026, 9, 19);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ClientTodaySection(
            today: saturday,
            calendar: _calendar(saturday, saturday.add(const Duration(days: 60))),
          ),
        ),
      ));

      expect(find.text('Home for the weekend'), findsNWidgets(2));
      expect(find.text('At home today'), findsNothing);
    });
  });

  group('next 7 days', () {
    testWidgets('marks closures and full days on the strip', (tester) async {
      final wednesday = _today.add(const Duration(days: 1));
      final friday = _today.add(const Duration(days: 3));
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e, closures: {
            wednesday: CalendarClosure(closureType: ClosureType.reduced, reason: 'Staff training'),
          }, full: {
            friday
          }),
        ),
      );

      expect(find.text('Calendar'), findsOneWidget);
      expect(find.text('Reduced'), findsOneWidget);
      expect(find.text('Full'), findsOneWidget);
      // Tue..Mon — all seven weekday labels are on the strip.
      for (final day in ['Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon']) {
        expect(find.text(day), findsWidgets, reason: day);
      }
    });
  });

  group('needs your attention', () {
    test('compute tallies each kind of item once', () {
      final attention = ClientAttention.compute(
        today: _today,
        dogs: [
          _dog(_buddy, vaccinationOverdue: true, contact: ''),
          // Vaccinated 1 Oct 2025: due 1 Oct 2026, 16 days out — due soon.
          _dog(_luna, lastVaccination: DateTime(2025, 10, 1)),
        ],
        invoices: [
          _invoice(id: 1, month: 7, overdue: true),
          _invoice(id: 2, month: 8),
          _invoice(id: 3, month: 6, status: 'PAID'),
        ],
        dayRequests: [_dayRequest(id: '1'), _dayRequest(id: '2', status: RequestStatus.approved)],
        boarding: [
          _stay(
            id: 1,
            dogs: const ['Buddy'],
            start: DateTime(2026, 10, 1),
            end: DateTime(2026, 10, 3),
            status: BoardingRequestStatus.pending,
          ),
        ],
        queries: [_query(id: 1, unread: true), _query(id: 2)],
        calendar: _calendar(_today, _today.add(const Duration(days: 60)), waitlist: {
          _today.add(const Duration(days: 3)): [
            CalendarWaitlistEntry(id: 9, dogId: '7', status: 'NOTIFIED'),
          ],
          _today.add(const Duration(days: 5)): [
            CalendarWaitlistEntry(id: 10, dogId: '8', status: 'WAITING'),
          ],
        }),
      );

      expect(attention.overdueInvoices, 1);
      expect(attention.unpaidInvoices, 1);
      expect(attention.vaccinationOverdue.map((d) => d.name), ['Buddy']);
      expect(attention.vaccinationDueSoon.map((d) => d.name), ['Luna']);
      expect(attention.pendingDayRequests, 1);
      expect(attention.pendingBoarding, 1);
      expect(attention.unreadReplies, 1);
      expect(attention.waitlistOffers, 1);
      expect(attention.missingContacts.map((d) => d.name), ['Buddy']);
      expect(attention.total, 9);
    });

    testWidgets('only the items that apply are listed', (tester) async {
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e),
          invoices: [_invoice(id: 1, month: 8, overdue: true, due: DateTime(2026, 9, 1))],
          queries: [_query(id: 1, unread: true)],
        ),
        dogs: [_dog(_buddy), _dog(_luna, emergency: null)],
      );

      expect(find.text('Needs Your Attention'), findsOneWidget);
      expect(find.text('Invoice overdue'), findsOneWidget);
      expect(find.text('Unread replies from staff'), findsOneWidget);
      expect(find.text('Contact number missing'), findsOneWidget);
      expect(find.text('Luna'), findsNWidgets(2)); // her dog row and the tile subtitle
      expect(find.text('Vaccination overdue'), findsNothing);
      expect(find.text('Invoice awaiting payment'), findsNothing);
      expect(find.text('Nothing needs your attention'), findsNothing);
    });

    testWidgets('an empty plate is one reassuring card', (tester) async {
      await _pump(
        tester,
        _FakeDataService(calendarFor: (s, e) => _calendar(s, e)),
        dogs: [_dog(_buddy)],
      );

      expect(find.text('Nothing needs your attention'), findsOneWidget);
    });
  });

  group('billing', () {
    testWidgets('shows the newest live invoice, and nothing when there are none',
        (tester) async {
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e),
          invoices: [
            _invoice(id: 1, month: 7, status: 'PAID'),
            _invoice(id: 2, month: 9, status: 'VOID'),
            _invoice(id: 3, month: 8, status: 'PART_PAID', paid: 100, due: DateTime(2026, 9, 30)),
          ],
        ),
      );

      expect(find.text('Billing'), findsOneWidget);
      expect(find.text('£280.00 · August 2026'), findsOneWidget);
      expect(find.text('Partially paid · £180.00 to pay · due 30/09/26'), findsOneWidget);
    });

    testWidgets('no invoices means no billing section', (tester) async {
      await _pump(tester, _FakeDataService(calendarFor: (s, e) => _calendar(s, e)));
      expect(find.text('Billing'), findsNothing);
    });

    test('latest ignores void invoices and orders by period', () {
      final latest = ClientBillingCard.latest([
        _invoice(id: 1, month: 7),
        _invoice(id: 2, month: 9, status: 'VOID'),
        _invoice(id: 3, month: 8),
      ]);
      expect(latest?.id, 3);
      expect(ClientBillingCard.latest(const []), isNull);
    });
  });

  group('upcoming boarding', () {
    testWidgets('lists confirmed and pending stays, soonest first', (tester) async {
      final fake = _FakeDataService(
        calendarFor: (s, e) => _calendar(s, e),
        boarding: [
          _stay(
            id: 1,
            dogs: const ['Buddy'],
            start: DateTime(2026, 10, 10),
            end: DateTime(2026, 10, 14),
            status: BoardingRequestStatus.pending,
          ),
          _stay(
            id: 2,
            dogs: const ['Luna'],
            start: DateTime(2026, 9, 13),
            end: DateTime(2026, 9, 18),
            carer: 'Sam',
          ),
          // Over — history, not the plan.
          _stay(id: 3, dogs: const ['Rex'], start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 5)),
          // Called off — likewise.
          _stay(
            id: 4,
            dogs: const ['Milo'],
            start: DateTime(2026, 11, 1),
            end: DateTime(2026, 11, 3),
            status: BoardingRequestStatus.cancelled,
          ),
        ],
      );
      await _pump(tester, fake);

      expect(find.text('Upcoming Boarding'), findsOneWidget);
      expect(find.text('Confirmed · boarding now · with Sam'), findsOneWidget);
      expect(find.text('Awaiting approval'), findsOneWidget);
      expect(find.text('Rex'), findsNothing);
      expect(find.text('Milo'), findsNothing);

      final rows = ClientBoardingSection.upcoming(fake.boarding, _today);
      expect(rows.map((r) => r.id), [2, 1]);
    });

    testWidgets('no boarding is an empty state, not a blank', (tester) async {
      await _pump(tester, _FakeDataService(calendarFor: (s, e) => _calendar(s, e)));
      expect(find.text('No boarding booked'), findsOneWidget);
    });
  });

  group('closures', () {
    testWidgets('lists what is coming, newest last', (tester) async {
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e),
          closures: [
            ClosureDay(id: 2, date: DateTime(2026, 12, 25), closureType: ClosureType.closed, reason: 'Christmas Day'),
            ClosureDay(id: 1, date: DateTime(2026, 10, 2), closureType: ClosureType.reduced),
            // Already gone.
            ClosureDay(id: 0, date: DateTime(2026, 8, 31), closureType: ClosureType.closed, reason: 'Bank holiday'),
          ],
        ),
      );

      await _scrollToBottom(tester);
      expect(find.text('Holidays & Closures'), findsOneWidget);
      expect(find.text('Fri 02/10/26'), findsOneWidget);
      expect(find.text('Reduced Capacity'), findsOneWidget);
      expect(find.text('Fri 25/12/26'), findsOneWidget);
      expect(find.text('Closed · Christmas Day'), findsOneWidget);
      expect(find.text('Bank holiday'), findsNothing);
    });

    testWidgets('none coming up says so', (tester) async {
      await _pump(tester, _FakeDataService(calendarFor: (s, e) => _calendar(s, e)));
      await _scrollToBottom(tester);
      expect(find.text('No closures in the next 90 days'), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('a boarding failure degrades only its own section', (tester) async {
      await _pump(
        tester,
        _FakeDataService(
          calendarFor: (s, e) => _calendar(s, e, attending: {_today: [_in(_buddy)]}),
          failBoarding: true,
        ),
      );

      expect(find.text('In daycare today'), findsOneWidget);
      expect(find.text("Couldn't load boarding — pull down to try again"), findsNWidgets(2));
      expect(find.text('No boarding booked'), findsNothing);
    });

    testWidgets('a calendar failure offers a retry', (tester) async {
      await _pump(
        tester,
        _FakeDataService(calendarFor: (s, e) => _calendar(s, e), failCalendar: true),
      );

      expect(find.text("Couldn't load your dashboard"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  testWidgets('quick actions offer the three things owners come to do', (tester) async {
    await _pump(tester, _FakeDataService(calendarFor: (s, e) => _calendar(s, e)));

    await tester.tap(find.text('Quick Actions'));
    await tester.pumpAndSettle();

    expect(find.text('Book or cancel a day'), findsOneWidget);
    expect(find.text('Request boarding'), findsOneWidget);
    expect(find.text('Contact staff'), findsOneWidget);
  });
}
