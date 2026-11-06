import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/owner_calendar.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/widgets/calendar_feed_sheet.dart';

final _link = CalendarFeedLink(
  url: 'https://example.com/api/calendar-feed/abc.ics',
  webcalUrl: 'webcal://example.com/api/calendar-feed/abc.ics',
);

class _FakeDataService extends MockDataService {
  CalendarFeedLink? link;
  int creates = 0;
  int deletes = 0;

  @override
  Future<CalendarFeedLink?> getCalendarFeedLink() async => link;

  @override
  Future<CalendarFeedLink> createCalendarFeedLink() async {
    creates++;
    return link = _link;
  }

  @override
  Future<void> deleteCalendarFeedLink() async {
    deletes++;
    link = null;
  }
}

void main() {
  late _FakeDataService service;

  setUp(() {
    service = _FakeDataService();
    getIt.allowReassignment = true;
    getIt.registerSingleton<DataService>(service);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CalendarFeedSheet())));
    await tester.pumpAndSettle();
  }

  test('iOS uses webcal, everything else goes through Google Calendar', () {
    expect(calendarSubscribeUri(_link, TargetPlatform.iOS).scheme, 'webcal');
    final android = calendarSubscribeUri(_link, TargetPlatform.android);
    expect(android.host, 'calendar.google.com');
    expect(android.queryParameters['cid'], _link.webcalUrl);
  });

  test('a null link from the API parses as no link', () {
    expect(CalendarFeedLink.fromJson({'url': null, 'webcal_url': null}), isNull);
  });

  testWidgets('no link: nothing to turn off, and opening makes none', (tester) async {
    await pump(tester);
    expect(find.text('Turn off this link'), findsNothing);
    expect(service.creates, 0);
  });

  testWidgets('copying makes the link and offers to turn it off', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(service.creates, 1);
    expect(find.text('Turn off this link'), findsOneWidget);
  });

  testWidgets('turning off asks first, then removes the link', (tester) async {
    service.link = _link;
    await pump(tester);
    await tester.tap(find.text('Turn off this link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(service.deletes, 1);
    expect(find.text('Turn off this link'), findsNothing);
    expect(find.text('Link turned off.'), findsOneWidget);
  });
}
