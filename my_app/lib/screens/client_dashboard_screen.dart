import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/boarding_request.dart';
import '../models/closure_day.dart';
import '../models/date_change_request.dart';
import '../models/dog.dart';
import '../models/group_media.dart';
import '../models/invoice.dart';
import '../models/owner_calendar.dart';
import '../models/support_query.dart';
import '../services/data_service.dart';
import '../services/no_connection_exception.dart';
import '../services/service_locator.dart';
import '../widgets/app_sheets.dart';
import '../widgets/new_query_dialog.dart';
import '../widgets/no_connection_widget.dart';
import '../widgets/page_body.dart';
import '../widgets/quick_actions_fab.dart';
import '../widgets/skeleton_loaders.dart';
import 'boarding_request_list_screen.dart';
import 'closure_days_screen.dart';
import 'dashboard/client_attention_section.dart';
import 'dashboard/client_billing_card.dart';
import 'dashboard/client_boarding_section.dart';
import 'dashboard/client_closures_section.dart';
import 'dashboard/client_photos_section.dart';
import 'feed_post_screen.dart';
import 'dashboard/client_today_section.dart';
import 'dashboard/client_week_strip.dart';
import 'dog_home_screen.dart';
import 'edit_dog_screen.dart';
import 'my_calendar_screen.dart';
import 'my_payments_screen.dart';
import 'query_list_screen.dart';
import 'request_boarding_screen.dart';
import 'vaccinations_screen.dart';

/// The owner's Dashboard tab — the client counterpart of the staff
/// `UnifiedDashboardScreen`. Top to bottom: where each dog is today and when
/// it is next in, the next seven days, what needs the owner's attention, the
/// latest invoice, upcoming boarding, the newest photos of their dogs, and
/// closures coming up — with a Quick Actions button for the things owners
/// most often come to the app to do.
///
/// Every call is owner-permitted and they are fetched together. The calendar
/// is the page — if it fails there is nothing to show — whereas any other
/// fetch failing only degrades its own section and raises a banner.
class ClientDashboardScreen extends StatefulWidget {
  /// The owner's dogs as the home screen already holds them, for avatars,
  /// vaccination/contact checks and tapping through to a profile. May still
  /// be loading (empty) on the first frame; the calendar carries its own dog
  /// names, so nothing waits on it.
  final List<Dog> dogs;

  /// Switches the home screen to the Feed tab (the photos strip's target).
  final VoidCallback? onSwitchToFeed;

  /// The clock, for tests only — production leaves it null and reads the real
  /// one. Every section here is about "today", so a test that named a fixed
  /// date without pinning this would pass on every day but that one.
  final DateTime? now;

  const ClientDashboardScreen({
    super.key,
    this.dogs = const [],
    this.onSwitchToFeed,
    this.now,
  });

  @override
  State<ClientDashboardScreen> createState() => _ClientDashboardScreenState();
}

class _ClientDashboardScreenState extends State<ClientDashboardScreen> {
  final DataService _dataService = getIt<DataService>();

  /// How far ahead "next in" looks. The calendar endpoint caps a range at
  /// 92 days; two months is plenty for a dog booked in weekly or fortnightly.
  static const int _horizonDays = 60;

  /// Closures are worth a heads-up further out than bookings.
  static const int _closureHorizonDays = 90;

  OwnerCalendar? _calendar;
  Object? _calendarError;
  List<BoardingRequest> _boarding = const [];
  List<Invoice> _invoices = const [];
  List<DateChangeRequest> _dayRequests = const [];
  List<SupportQuery> _queries = const [];
  List<ClosureDay> _closures = const [];
  List<GroupMedia> _photos = const [];

  /// Sections whose fetch failed on the last load, by name.
  final Set<String> _failed = {};
  bool _loading = true;

  DateTime get _today {
    final n = widget.now ?? DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final today = _today;
    // Each fetch swallows its own error so none can surface as an unhandled
    // async failure while the others are still being awaited.
    await Future.wait([
      _loadCalendar(today),
      _fetch('boarding', () async => _boarding = await _dataService.getBoardingRequests()),
      _fetch('invoices', () async => _invoices = await _dataService.getInvoices()),
      _fetch('requests', () async => _dayRequests = await _dataService.getDateChangeRequests()),
      _fetch('messages', () async => _queries = await _dataService.getSupportQueries()),
      _fetch(
        'closures',
        () async => _closures = await _dataService.getClosureDays(
          fromDate: today,
          toDate: today.add(const Duration(days: _closureHorizonDays)),
        ),
      ),
    ]);
    // The photo strip is per dog, and the calendar is what names the dogs.
    await _loadPhotos();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fetch(String name, Future<void> Function() run) async {
    try {
      await run();
      if (mounted) setState(() => _failed.remove(name));
    } catch (_) {
      if (mounted) setState(() => _failed.add(name));
    }
  }

  Future<void> _loadCalendar(DateTime today) async {
    try {
      final calendar = await _dataService.getOwnerCalendar(
        start: today,
        end: today.add(const Duration(days: _horizonDays)),
      );
      if (!mounted) return;
      setState(() {
        _calendar = calendar;
        _calendarError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _calendarError = e);
    }
  }

  Future<void> _loadPhotos() async {
    final dogs = _calendar?.dogs ?? const [];
    if (dogs.isEmpty) return;
    await _fetch('photos', () async {
      final pages = await Future.wait([
        for (final dog in dogs) _dataService.getFeedPage(dogId: dog.id),
      ]);
      _photos = ClientPhotosSection.merge(pages.map((p) => p.items));
    });
  }

  // ── Navigation ─────────────────────────────────────────────────────

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    // Whatever was done there (a request, a waitlist join, an edit) belongs
    // on the dashboard the moment they come back.
    _load();
  }

  /// One dog opens directly; several ask which. Null when there are none
  /// loaded yet.
  Future<Dog?> _pickDog(String title, [List<Dog>? from]) async {
    final dogs = from ?? widget.dogs;
    if (dogs.isEmpty) return null;
    if (dogs.length == 1) return dogs.first;
    return showAppActionSheet<Dog>(
      context,
      title: title,
      actions: [for (final d in dogs) AppSheetAction(label: d.name, value: d)],
    );
  }

  Future<void> _openDog(CalendarDogRef ref) async {
    final dog = widget.dogs.where((d) => d.id == ref.id).firstOrNull;
    // Dogs list not in yet — the calendar is the next best place.
    if (dog == null) return _openCalendar();
    await _push(DogHomeScreen(dog: dog, isStaff: false));
  }

  Future<void> _openCalendar() => _push(const MyCalendarScreen());

  Future<void> _openPayments() => _push(const MyPaymentsScreen());

  Future<void> _openInvoice(Invoice invoice) =>
      _push(MyPaymentsScreen(openInvoiceId: invoice.id));

  Future<void> _openBoardingList() =>
      _push(const BoardingRequestListScreen(isStaff: false));

  Future<void> _requestBoarding() => _push(const RequestBoardingScreen());

  Future<void> _openQueries() =>
      _push(const QueryListScreen(isStaff: false));

  Future<void> _openClosures() => _push(const ClosureDaysScreen(isStaff: false));

  Future<void> _openVaccinations(List<Dog> dogs) async {
    final dog = await _pickDog('Which dog?', dogs);
    if (dog == null || !mounted) return;
    await _push(VaccinationsScreen(dog: dog, isStaff: false));
  }

  Future<void> _openDogDetails(List<Dog> dogs) async {
    final dog = await _pickDog('Which dog?', dogs);
    if (dog == null || !mounted) return;
    await _push(EditDogScreen(dog: dog));
  }

  /// Booking an extra day or cancelling one happens on the dog's own
  /// calendar (tap a free day to add it, a booked day to change it).
  Future<void> _changeDays() async {
    final dog = await _pickDog("Whose days?");
    if (dog == null || !mounted) return;
    await _push(DogHomeScreen(dog: dog, isStaff: false));
  }

  Future<void> _contactStaff() async {
    if (await showNewQueryDialog(context)) _load();
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final calendar = _calendar;
    if (calendar == null) {
      if (_loading) return const PageBody(child: ListTileSkeletonList());
      final error = _calendarError;
      if (error != null && NoConnectionException.isNetworkError(error)) {
        return NoConnectionWidget(onRetry: _load);
      }
      return PageBody(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Couldn't load your dashboard",
                    style: TextStyle(color: Colors.grey[600])),
                const SizedBox(height: 12),
                FilledButton(onPressed: _load, child: const Text('Try again')),
              ],
            ),
          ),
        ),
      );
    }

    final today = _today;
    final imageUrls = {for (final d in widget.dogs) d.id: d.profileImageUrl};
    final attention = ClientAttention.compute(
      today: today,
      dogs: widget.dogs,
      invoices: _invoices,
      dayRequests: _dayRequests,
      boarding: _boarding,
      queries: _queries,
      calendar: calendar,
    );
    final latestInvoice = ClientBillingCard.latest(_invoices);
    const gap = SizedBox(height: 24);

    return Scaffold(
      floatingActionButton: QuickActionsFab(actions: [
        QuickFabAction(
          icon: PiconsDuotone.calendarBlank,
          label: 'Book or cancel a day',
          onPressed: _changeDays,
        ),
        QuickFabAction(
          icon: PiconsDuotone.bed,
          label: 'Request boarding',
          color: Colors.deepPurple,
          onPressed: _requestBoarding,
        ),
        QuickFabAction(
          icon: PiconsDuotone.chats,
          label: 'Contact staff',
          onPressed: _contactStaff,
        ),
      ]),
      body: PageBody(
        child: RefreshIndicator.adaptive(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            // Room at the bottom so the FAB never covers the last row.
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              if (_failed.isNotEmpty) ...[
                _DegradedBanner(sections: _failed),
                const SizedBox(height: 12),
              ],
              ClientTodaySection(
                today: today,
                calendar: calendar,
                imageUrls: imageUrls,
                onOpenDog: _openDog,
                onOpenCalendar: _openCalendar,
              ),
              gap,
              ClientWeekStrip(
                today: today,
                calendar: calendar,
                onTap: (_) => _openCalendar(),
              ),
              gap,
              ClientAttentionSection(
                attention: attention,
                onOpenPayments: _openPayments,
                onOpenVaccinations: _openVaccinations,
                onOpenDayRequests: _changeDays,
                onOpenBoarding: _openBoardingList,
                onOpenQueries: _openQueries,
                onOpenCalendar: _openCalendar,
                onOpenDogDetails: _openDogDetails,
              ),
              if (latestInvoice != null) ...[
                gap,
                ClientBillingCard(
                  invoice: latestInvoice,
                  onTap: () => _openInvoice(latestInvoice),
                ),
              ],
              gap,
              ClientBoardingSection(
                today: today,
                boarding: _boarding,
                failed: _failed.contains('boarding'),
                onTap: (_) => _openBoardingList(),
                onRequest: _requestBoarding,
              ),
              if (_photos.isNotEmpty) ...[
                gap,
                ClientPhotosSection(
                  items: _photos,
                  onOpenFeed: widget.onSwitchToFeed,
                  onOpenItem: (item) => _push(FeedPostScreen(media: item)),
                ),
              ],
              gap,
              ClientClosuresSection(
                today: today,
                closures: _closures,
                horizonDays: _closureHorizonDays,
                onOpen: _openClosures,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DegradedBanner extends StatelessWidget {
  final Set<String> sections;
  const _DegradedBanner({required this.sections});

  @override
  Widget build(BuildContext context) {
    final names = sections.toList()..sort();
    return Card(
      color: AppColors.warning.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Picon(PiconsDuotone.warningCircle, color: AppColors.warning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Couldn't load ${names.join(', ')} — pull down to try again",
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
