import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/boarding_request.dart';
import 'package:paws4thoughtdogs/models/date_change_request.dart';
import 'package:paws4thoughtdogs/screens/dashboard/dashboard_counts.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';

class _CountingDataService extends MockDataService {
  final List<String> calls = [];

  @override
  Future<int> getUnresolvedQueryCount() async {
    calls.add('queries');
    return 3;
  }

  @override
  Future<int> getPendingIntakeRequestCount() async {
    calls.add('booking_forms');
    return 2;
  }

  @override
  Future<int> getUnreadInquiryCount() async {
    calls.add('inquiries');
    return 4;
  }

  @override
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId}) async {
    calls.add('date_requests');
    return [];
  }

  @override
  Future<List<BoardingRequest>> getBoardingRequests() async {
    calls.add('boarding');
    return [];
  }
}

void main() {
  test('an owner only ever loads the Contact Staff count', () async {
    final service = _CountingDataService();
    final counts = DashboardCounts(dataService: service, isStaff: false);

    await counts.refreshInbox();
    await counts.refresh();

    expect(service.calls.toSet(), {'queries'});
    expect(counts.unresolvedQueryCount, 3);
  });

  test('staff inbox counts follow the flags, and listeners hear each one', () async {
    final service = _CountingDataService();
    final counts = DashboardCounts(dataService: service, isStaff: false);
    var notified = 0;
    counts.addListener(() => notified++);

    // The profile arrives after the store is built.
    counts.updatePermissions(
      isStaff: true,
      canViewInquiries: false,
      canManageRequests: true,
      canManageBoarding: false,
    );
    await counts.refreshInbox();

    expect(service.calls, containsAll(['queries', 'booking_forms', 'date_requests']));
    expect(service.calls, isNot(contains('inquiries')));
    expect(service.calls, isNot(contains('boarding')));
    expect(counts.pendingBookingFormCount, 2);
    expect(notified, greaterThanOrEqualTo(3));

    counts.updatePermissions(
      isStaff: true,
      canViewInquiries: true,
      canManageRequests: true,
      canManageBoarding: true,
    );
    await counts.refreshInbox();
    expect(counts.unreadInquiryCount, 4);
  });

  test('one refresh fetches the boarding list once for both of its readers', () async {
    final service = _CountingDataService();
    final counts = DashboardCounts(
      dataService: service,
      canManageBoarding: true,
    );

    await counts.refresh();

    expect(service.calls.where((c) => c == 'boarding'), hasLength(1));
  });
}
