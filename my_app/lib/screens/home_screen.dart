import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:upgrader/upgrader.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../models/intake_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../services/no_connection_exception.dart';
import '../services/notification_service.dart';
import '../services/offline_prefetch_service.dart';
import '../widgets/grouped_section.dart';
import '../widgets/no_connection_widget.dart';
import '../widgets/skeleton_loaders.dart';
import 'dog_home_screen.dart';
import 'profile_screen.dart';
import 'add_dog_screen.dart';
import 'booking_form_screen.dart';
import 'booking_requests_screen.dart';
import 'staff_notifications_screen.dart';
import 'feed_screen.dart';
import 'boarding_request_list_screen.dart';
import 'unified_dashboard_screen.dart';
import 'query_list_screen.dart';
import 'closure_days_screen.dart';
import 'my_calendar_screen.dart';
import 'staff_availability_screen.dart';
import 'inquiry_list_screen.dart';
import 'fleet_screen.dart';
import 'traffic_alert_screen.dart';
import 'my_payments_screen.dart';
import 'customer_payments_screen.dart';

class HomeScreen extends StatefulWidget {
  final String? scrollToPostId;

  /// Deep-link target set by notification taps.
  /// Values: 'requests', 'boarding_requests', 'booking_forms', 'queries', 'inquiries', 'dogs', 'feed'
  final String? initialRoute;

  /// Optional payload for the deep link (e.g. a dog ID or request ID).
  final String? routePayload;

  const HomeScreen({super.key, this.scrollToPostId, this.initialRoute, this.routePayload});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final DataService _dataService = getIt<DataService>();
  // final AuthService _authService = AuthService(); // Removed unused
  final NotificationService _notificationService = NotificationService();
  
  List<Dog> _allDogs = [];
  List<Dog> _filteredDogs = [];
  List<IntakeRequest> _myIntakeRequests = [];
  bool _loadingDogs = true;
  bool _isOffline = false;
  final TextEditingController _searchController = TextEditingController();

  bool _isStaff = false;
  bool _isSuperuser = false;
  int? _myUserId;
  bool _canAssignDogs = false;
  bool _canAddFeedMedia = false;
  bool _canManageRequests = false;
  bool _canReplyQueries = false;
  bool _canManageStaff = false;
  bool _canViewInquiries = false;
  bool _canManageVehicles = false;
  bool _canManagePayments = false;
  bool _canManageBoarding = false;
  int _currentIndex = 1;
  int _pendingRequestCount = 0;
  int _unresolvedQueryCount = 0;
  int _unreadInquiryCount = 0;
  String _appVersion = '';
  final GlobalKey<UnifiedDashboardScreenState> _dashboardKey = GlobalKey();
  bool _initialRouteHandled = false;

  // Staff filter for dashboard navigation
  int? _dogGroupsStaffFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDogs();
    _checkStaffStatus();
    _loadAppVersion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isOffline) _refresh();
      // Re-warm the offline caches on foreground (throttled inside the
      // service), e.g. a staff member checking the app before setting off.
      if (_isStaff) getIt<OfflinePrefetchService>().prefetchForToday();
    }
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = 'v${info.version} (${info.buildNumber})';
      });
    }
  }

  Future<void> _loadDogs() async {
    if (!mounted) return;
    // Only show loading spinner on initial load, not on refresh
    final isInitialLoad = _allDogs.isEmpty;

    // Seed from the offline cache so the list renders instantly instead of
    // spinning while a (possibly doomed) network request runs; the fresh
    // result below replaces it when it arrives.
    if (isInitialLoad) {
      final cached = _dataService.cachedDogs();
      if (cached != null && mounted) {
        final dogs = cached.data
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        setState(() {
          _allDogs = dogs;
          _filteredDogs = _applyFilter(_searchController.text);
        });
      }
    }

    setState(() {
      if (isInitialLoad && _allDogs.isEmpty) _loadingDogs = true;
      _isOffline = false;
    });

    try {
      final dogs = await _dataService.getDogs();
      // Alphabetical sort
      dogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      // With no dogs attached, the empty state offers the booking form — so
      // check whether the owner already has a submission in flight.
      List<IntakeRequest> intakeRequests = _myIntakeRequests;
      if (dogs.isEmpty) {
        try {
          intakeRequests = await _dataService.getIntakeRequests();
        } catch (_) {
          intakeRequests = [];
        }
      }

      if (mounted) {
        setState(() {
          _allDogs = dogs;
          _myIntakeRequests = intakeRequests;
          _loadingDogs = false;
          // Re-apply filter if search text exists
          _filteredDogs = _applyFilter(_searchController.text);
        });
      }
    } catch (e) {
      if (mounted) {
        final offline = NoConnectionException.isNetworkError(e);
        setState(() {
          _loadingDogs = false;
          _isOffline = offline;
        });
        if (!offline) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to load dogs: $e')),
          );
        }
      }
    }
  }

  void _filterDogs(String query) {
    final filtered = _applyFilter(query);
    setState(() {
      _filteredDogs = filtered;
    });
  }

  List<Dog> _applyFilter(String query) {
    if (query.isEmpty) {
      return _allDogs;
    }
    final lowerQuery = query.toLowerCase();
    return _allDogs.where((dog) {
      if (dog.name.toLowerCase().contains(lowerQuery)) return true;
      if (dog.ownerDetails != null) {
        if (dog.ownerDetails!.username.toLowerCase().contains(lowerQuery)) return true;
      }
      for (final owner in dog.additionalOwners) {
        if (owner.username.toLowerCase().contains(lowerQuery)) return true;
      }
      return false;
    }).toList();
  }

  Future<void> _checkStaffStatus() async {
    try {
      final profile = await _dataService.getProfile();
      if (mounted) {
        setState(() {
          _isStaff = profile.isStaff;
          _isSuperuser = profile.isSuperuser;
          _myUserId = profile.userId;
          _canAssignDogs = profile.canAssignDogs;
          _canAddFeedMedia = profile.canAddFeedMedia;
          _canManageRequests = profile.canManageRequests;
          _canReplyQueries = profile.canReplyQueries;
          _canManageStaff = profile.canManageStaff;
          _canViewInquiries = profile.canViewInquiries;
          _canManageVehicles = profile.canManageVehicles;
          _canManagePayments = profile.canManagePayments;
          _canManageBoarding = profile.canManageBoarding;
        });
        // Load pending requests count and subscribe to notifications
        if (profile.isStaff) {
          // Default to Dashboard tab for staff (unless deep-link overrides)
          if (widget.initialRoute == null && _currentIndex == 1) {
            setState(() => _currentIndex = 2);
          }
          // Warm the offline caches (route + dog photos) while on WiFi, so
          // the app keeps working through signal dead zones mid-route.
          getIt<OfflinePrefetchService>().prefetchForToday();
          await _loadPendingRequestCount();
          await _notificationService.subscribeToTopic('staff_notifications');
        } else {
          await _notificationService.unsubscribeFromTopic('staff_notifications');
        }
        await _loadUnresolvedQueryCount();
        if (profile.isStaff && profile.canViewInquiries) {
          await _loadUnreadInquiryCount();
        }
        // Handle deep-link navigation after permissions are known
        _handleInitialRoute();
      }
    } catch (e) {
      if (mounted) {
        if (NoConnectionException.isNetworkError(e)) {
          // Only block the app when there's nothing cached to show; a cold
          // profile cache alone mustn't blank out a cached dogs list.
          if (_allDogs.isEmpty) setState(() => _isOffline = true);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to check staff status: $e'), backgroundColor: AppColors.error),
          );
        }
      }
    }
  }

  Future<void> _loadPendingRequestCount() async {
    if (!_isStaff) return;
    try {
      final dateRequests = await _dataService.getDateChangeRequests();
      final pendingDateCount = dateRequests.where((r) => r.status == RequestStatus.pending).length;

      // Pending boardings only alert staff who can act on them.
      var pendingBoardingCount = 0;
      if (_canManageBoarding) {
        final boardingRequests = await _dataService.getBoardingRequests();
        pendingBoardingCount = boardingRequests.where((r) => r.status == BoardingRequestStatus.pending).length;
      }

      if (mounted) {
        setState(() => _pendingRequestCount = pendingDateCount + pendingBoardingCount);
      }
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _loadUnresolvedQueryCount() async {
    try {
      final count = await _dataService.getUnresolvedQueryCount();
      if (mounted) {
        setState(() => _unresolvedQueryCount = count);
      }
    } catch (_) {}
  }

  Future<void> _loadUnreadInquiryCount() async {
    try {
      final count = await _dataService.getUnreadInquiryCount();
      if (mounted) {
        setState(() => _unreadInquiryCount = count);
      }
    } catch (_) {}
  }

  void _refresh() {
    _loadDogs();
    _loadPendingRequestCount();
    _loadUnresolvedQueryCount();
    if (_canViewInquiries) _loadUnreadInquiryCount();
  }

  /// Navigate to the deep-link target screen after profile/permissions are loaded.
  void _handleInitialRoute() {
    if (_initialRouteHandled || widget.initialRoute == null) return;
    _initialRouteHandled = true;

    // Delay slightly to let the widget tree settle
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (widget.initialRoute) {
        case 'requests':
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => StaffNotificationsScreen(
                canManageRequests: _canManageRequests,
                canManageBoarding: _canManageBoarding,
              ),
            ),
          );
          break;
        case 'boarding_requests':
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BoardingRequestListScreen(
                isStaff: _isStaff,
                canManageBoarding: _canManageBoarding,
              ),
            ),
          );
          break;
        case 'queries':
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => QueryListScreen(
                isStaff: _isStaff,
                canReplyQueries: _canReplyQueries,
              ),
            ),
          );
          break;
        case 'inquiries':
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const InquiryListScreen()),
          );
          break;
        case 'booking_forms':
          _openBookingForms();
          break;
        case 'dogs':
          // If a specific dog ID was provided and we have the dog data, navigate to it
          final dogId = widget.routePayload;
          if (dogId != null && _allDogs.isNotEmpty) {
            final dog = _allDogs.where((d) => d.id.toString() == dogId).firstOrNull;
            if (dog != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DogHomeScreen(dog: dog, isStaff: _isStaff),
                ),
              );
              break;
            }
          }
          // Otherwise just switch to dogs tab
          setState(() => _currentIndex = 0);
          break;
        case 'feed':
          setState(() => _currentIndex = 1);
          break;
        case 'payments':
          // Staff payment managers land on the management screen; owners on
          // their own invoice list (optionally straight into one invoice).
          if (_isStaff && _canManagePayments) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomerPaymentsScreen()),
            );
          } else {
            final invoiceId = int.tryParse(widget.routePayload ?? '');
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MyPaymentsScreen(openInvoiceId: invoiceId),
              ),
            );
          }
          break;
        case 'customer_payments':
          if (_isStaff && _canManagePayments) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomerPaymentsScreen()),
            );
          }
          break;
      }
    });
  }



  Future<void> _addDog() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddDogScreen()),
    );
    if (result == true) {
      _refresh();
    }
  }

  Future<void> _openBookingForm() async {
    final submitted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const BookingFormScreen()),
    );
    if (submitted == true) _refresh();
  }

  Future<void> _openBookingForms() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => BookingRequestsScreen(isStaff: _isStaff)),
    );
    if (changed == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return UpgradeAlert(
      shouldPopScope: () => true,
      child: Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => setState(() => _currentIndex = 1),
          child: Image.asset('assets/logo.png', height: 32),
        ),
        actions: [
          if (_isStaff)
            Stack(
              children: [
                IconButton(
                  icon: Picon(PiconsDuotone.bell),
                  tooltip: 'Date Change Requests',
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => StaffNotificationsScreen(canManageRequests: _canManageRequests, canManageBoarding: _canManageBoarding)),
                    );
                    _loadPendingRequestCount();
                  },
                ),
                if (_pendingRequestCount > 0)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                      child: Center(
                        child: Text(
                          '$_pendingRequestCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
      drawer: _buildDrawer(),
      floatingActionButton: _currentIndex == 0 && _isStaff
          ? FloatingActionButton.extended(
              onPressed: _addDog,
              icon: Picon(PiconsDuotone.plus),
              label: const Text('Add Dog'),
            )
          : null,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).bottomNavigationBarTheme.backgroundColor,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerTheme.color ?? AppColors.iosSeparator,
              width: 0.5,
            ),
          ),
        ),
        child: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) async {
          // If non-staff user with a single dog taps "My Dogs", go straight to dog profile
          if (index == 0 && !_isStaff && !_loadingDogs && _allDogs.length == 1) {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DogHomeScreen(dog: _allDogs.first, isStaff: false),
              ),
            );
            if (result == 'deleted') _refresh();
            return;
          }
          setState(() {
            _currentIndex = index;
            if (index != 2) _dogGroupsStaffFilter = null;
          });
          if (_isOffline) _refresh();
        },
        items: [
          BottomNavigationBarItem(
            icon: Picon(PiconsDuotone.pawPrint),
            label: _isStaff ? 'All Dogs' : (_allDogs.length == 1 ? _allDogs.first.name : 'My Dogs'),
          ),
          BottomNavigationBarItem(
            icon: Picon(PiconsDuotone.images),
            label: 'Feed',
          ),
          if (_isStaff)
            BottomNavigationBarItem(
              icon: Picon(PiconsDuotone.squaresFour),
              label: "Dashboard",
            ),
        ],
        ),
      ),
      // Full-screen offline block only when there is truly nothing to show —
      // with a warm cache the app keeps working offline (saved data).
      body: _isOffline && _allDogs.isEmpty
          ? NoConnectionWidget(onRetry: _refresh)
          : _currentIndex == 0
              ? _buildDogsView()
              : _currentIndex == 1
                  ? FeedScreen(isStaff: _isStaff, canAddFeedMedia: _canAddFeedMedia, scrollToPostId: widget.scrollToPostId)
                  : UnifiedDashboardScreen(
                      key: _dashboardKey,
                      canAssignDogs: _canAssignDogs,
                      canManageRequests: _canManageRequests,
                      canReplyQueries: _canReplyQueries,
                      canViewInquiries: _canViewInquiries,
                      canAddFeedMedia: _canAddFeedMedia,
                      canManageVehicles: _canManageVehicles,
                      canManagePayments: _canManagePayments,
                      canManageBoarding: _canManageBoarding,
                      isStaff: _isStaff,
                      isSuperuser: _isSuperuser,
                      myUserId: _myUserId,
                      initialStaffId: _dogGroupsStaffFilter,
                      onSwitchToFeed: () => setState(() => _currentIndex = 1),
                    ),
    ),
    );
  }

  Widget _drawerChevron() => Picon(
        PiconsDuotone.caretRight,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );

  Widget _drawerBadge(int count) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.error,
          borderRadius: BorderRadius.circular(10),
        ),
        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
        child: Text(
          '$count',
          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
      );

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerTheme.color ?? AppColors.iosSeparator,
                  width: 0.5,
                ),
              ),
            ),
            child: Center(
              child: Image.asset('assets/logo.png', height: 48),
            ),
          ),
          GroupedSection(
            children: [
              ListTile(
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Picon(PiconsDuotone.chats),
                    if (_unresolvedQueryCount > 0)
                      Positioned(
                        right: -6,
                        top: -6,
                        child: _drawerBadge(_unresolvedQueryCount),
                      ),
                  ],
                ),
                title: const Text('Contact Staff'),
                trailing: _drawerChevron(),
                onTap: () async {
                  Navigator.pop(context); // close drawer
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => QueryListScreen(
                        isStaff: _isStaff,
                        canReplyQueries: _canReplyQueries,
                      ),
                    ),
                  );
                  _loadUnresolvedQueryCount();
                },
              ),
              ListTile(
                leading: Picon(PiconsDuotone.clipboardText),
                title: const Text('Booking Forms'),
                trailing: _drawerChevron(),
                onTap: () {
                  Navigator.pop(context); // close drawer
                  _openBookingForms();
                },
              ),
              if (_isStaff && _canViewInquiries)
                ListTile(
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Picon(PiconsDuotone.envelope),
                      if (_unreadInquiryCount > 0)
                        Positioned(
                          right: -6,
                          top: -4,
                          child: _drawerBadge(_unreadInquiryCount),
                        ),
                    ],
                  ),
                  title: const Text('Website Inquiries'),
                  trailing: _drawerChevron(),
                  onTap: () async {
                    Navigator.pop(context);
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const InquiryListScreen(),
                      ),
                    );
                    _loadUnreadInquiryCount();
                  },
                ),
              if (_isStaff)
                ListTile(
                  leading: Picon(PiconsDuotone.path),
                  title: const Text('Traffic Alert'),
                  onTap: () async {
                    Navigator.pop(context);
                    final sent = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(builder: (_) => const TrafficAlertScreen()),
                    );
                    if (sent == true && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Traffic alert sent'),
                          backgroundColor: AppColors.success,
                        ),
                      );
                    }
                  },
                ),
              if (_isStaff)
                ListTile(
                  leading: Picon(PiconsDuotone.van),
                  title: const Text('Fleet'),
                  trailing: _drawerChevron(),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FleetScreen(canManageVehicles: _canManageVehicles),
                      ),
                    );
                  },
                ),
              if (!_isStaff)
                ListTile(
                  leading: Picon(PiconsDuotone.currencyGbp),
                  title: const Text('My Payments'),
                  trailing: _drawerChevron(),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const MyPaymentsScreen()),
                    );
                  },
                ),
              if (_isStaff && _canManagePayments)
                ListTile(
                  leading: Picon(PiconsDuotone.currencyGbp),
                  title: const Text('Customer Payments'),
                  trailing: _drawerChevron(),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CustomerPaymentsScreen()),
                    );
                  },
                ),
              if (_isStaff)
                ListTile(
                  leading: Picon(PiconsDuotone.clock),
                  title: const Text('My Availability'),
                  trailing: _drawerChevron(),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StaffAvailabilityScreen(canAssignDogs: _canAssignDogs, canManageStaff: _canManageStaff),
                      ),
                    );
                  },
                ),
              ListTile(
                leading: Picon(PiconsDuotone.calendarCheck),
                title: const Text('My Calendar'),
                trailing: _drawerChevron(),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MyCalendarScreen(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: Picon(PiconsDuotone.calendarX),
                title: const Text('Holidays & Closures'),
                trailing: _drawerChevron(),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ClosureDaysScreen(isStaff: _isStaff),
                    ),
                  );
                },
              ),
            ],
          ),
          GroupedSection(
            children: [
              ListTile(
                leading: Picon(PiconsDuotone.user),
                title: const Text('Profile'),
                trailing: _drawerChevron(),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  );
                },
              ),
            ],
          ),
          if (_appVersion.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _appVersion,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
        ],
      ),
    );
  }


  Widget _buildDogsView() {
    if (_loadingDogs) {
      return const DogSkeletonList();
    }

    if (_allDogs.isEmpty) {
      final pendingIntake = _myIntakeRequests
          .where((r) => r.status == IntakeRequestStatus.pending)
          .firstOrNull;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Picon(PiconsDuotone.pawPrint, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No dogs yet!',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            if (_isStaff)
              const Text('Tap the button below to add your first dog.')
            else if (pendingIntake != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Your booking form for ${pendingIntake.dogNames} has been '
                  'submitted and is waiting for staff to review.',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _openBookingForms,
                icon: Picon(PiconsDuotone.clipboardText),
                label: const Text('View My Booking Form'),
              ),
            ] else ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Ready to book your dog into daycare? Fill out the booking '
                  'form and staff will confirm your place.\n\nAlready with us? '
                  'Contact staff to attach your dog to your profile instead.',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _openBookingForm,
                icon: Picon(PiconsDuotone.clipboardText),
                label: const Text('Fill Out Booking Form'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => QueryListScreen(isStaff: _isStaff),
                    ),
                  );
                },
                icon: Picon(PiconsDuotone.headset),
                label: const Text('Contact Staff'),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_allDogs.length > 1)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _isStaff ? 'Search by dog or owner name...' : 'Search dogs...',
                prefixIcon: Picon(PiconsDuotone.magnifyingGlass),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Picon(PiconsDuotone.x),
                        onPressed: () {
                          _searchController.clear();
                          _filterDogs('');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              ),
              onChanged: _filterDogs,
            ),
          ),
        
        Expanded(
          child: _filteredDogs.isEmpty
              ? Center(
                  child: Text(
                    'No dogs found matching "${_searchController.text}"',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                )
              : RefreshIndicator.adaptive(
                  onRefresh: () async => _loadDogs(),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: _filteredDogs.length,
                    itemBuilder: (context, index) {
                      final dog = _filteredDogs[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 16),
                        child: InkWell(
                          onTap: () async {
                            final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DogHomeScreen(dog: dog, isStaff: _isStaff),
                              ),
                            );
                            if (result == 'deleted') {
                              _refresh();
                            } else {
                              // The dog may have been edited on the profile
                              // screen; reload so the list reflects the latest
                              // server state (e.g. schedule type / days).
                              _loadDogs();
                            }
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (dog.profileImageUrl != null)
                                ClipRRect(
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                                  child: CachedNetworkImage(
                                    imageUrl: dog.profileImageUrl!,
                                    height: 200,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => Container(
                                      height: 200,
                                      color: Colors.grey[200],
                                      child: const Center(child: CircularProgressIndicator()),
                                    ),
                                    errorWidget: (context, url, error) =>
                                        SizedBox(height: 200, child: Center(child: Picon(PiconsDuotone.warningCircle))),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Text(
                                  dog.name,
                                  style: Theme.of(context).textTheme.headlineSmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

