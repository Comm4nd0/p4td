import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:upgrader/upgrader.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';
import '../services/no_connection_exception.dart';
import '../services/notification_service.dart';
import '../widgets/no_connection_widget.dart';
import '../widgets/skeleton_loaders.dart';
import 'dog_home_screen.dart';
import 'profile_screen.dart';
import 'add_dog_screen.dart';
import 'staff_notifications_screen.dart';
import 'feed_screen.dart';
import 'boarding_request_list_screen.dart';
import 'unified_dashboard_screen.dart';
import 'query_list_screen.dart';
import 'closure_days_screen.dart';
import 'staff_availability_screen.dart';
import 'inquiry_list_screen.dart';

class HomeScreen extends StatefulWidget {
  final String? scrollToPostId;

  /// Deep-link target set by notification taps.
  /// Values: 'requests', 'boarding_requests', 'queries', 'inquiries', 'dogs', 'feed'
  final String? initialRoute;

  /// Optional payload for the deep link (e.g. a dog ID or request ID).
  final String? routePayload;

  const HomeScreen({super.key, this.scrollToPostId, this.initialRoute, this.routePayload});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final DataService _dataService = ApiDataService();
  // final AuthService _authService = AuthService(); // Removed unused
  final NotificationService _notificationService = NotificationService();
  
  List<Dog> _allDogs = [];
  List<Dog> _filteredDogs = [];
  bool _loadingDogs = true;
  bool _isOffline = false;
  final TextEditingController _searchController = TextEditingController();

  bool _isStaff = false;
  int? _myUserId;
  bool _canAssignDogs = false;
  bool _canAddFeedMedia = false;
  bool _canManageRequests = false;
  bool _canReplyQueries = false;
  bool _canApproveTimeoff = false;
  bool _canViewInquiries = false;
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
    if (state == AppLifecycleState.resumed && _isOffline) {
      _refresh();
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
    setState(() {
      if (isInitialLoad) _loadingDogs = true;
      _isOffline = false;
    });

    try {
      final dogs = await _dataService.getDogs();
      // Alphabetical sort
      dogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      if (mounted) {
        setState(() {
          _allDogs = dogs;
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
          _myUserId = profile.userId;
          _canAssignDogs = profile.canAssignDogs;
          _canAddFeedMedia = profile.canAddFeedMedia;
          _canManageRequests = profile.canManageRequests;
          _canReplyQueries = profile.canReplyQueries;
          _canApproveTimeoff = profile.canApproveTimeoff;
          _canViewInquiries = profile.canViewInquiries;
        });
        // Load pending requests count and subscribe to notifications
        if (profile.isStaff) {
          // Default to Dashboard tab for staff (unless deep-link overrides)
          if (widget.initialRoute == null && _currentIndex == 1) {
            setState(() => _currentIndex = 2);
          }
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
          setState(() => _isOffline = true);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to check staff status: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _loadPendingRequestCount() async {
    if (!_isStaff) return;
    try {
      final dateRequests = await _dataService.getDateChangeRequests();
      final boardingRequests = await _dataService.getBoardingRequests();
      
      final pendingDateCount = dateRequests.where((r) => r.status == RequestStatus.pending).length;
      final pendingBoardingCount = boardingRequests.where((r) => r.status == BoardingRequestStatus.pending).length;
      
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
              builder: (_) => StaffNotificationsScreen(canManageRequests: _canManageRequests),
            ),
          );
          break;
        case 'boarding_requests':
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const BoardingRequestListScreen()),
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

  Future<void> _showTrafficAlertDialog() async {
    final detailController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            PhosphorIcon(PhosphorIconsDuotone.path, color: Colors.orange),
            SizedBox(width: 8),
            Text('Traffic Alert'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Send a traffic delay notification to all owners with dogs scheduled today. Which service is affected?'),
            const SizedBox(height: 12),
            TextField(
              controller: detailController,
              decoration: const InputDecoration(
                labelText: 'Additional detail (optional)',
                hintText: 'e.g. Accident on M1, expect 20 min delay',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'pickup'),
            icon: PhosphorIcon(PhosphorIconsDuotone.arrowUp, size: 18),
            label: const Text('Pickup'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'dropoff'),
            icon: PhosphorIcon(PhosphorIconsDuotone.arrowDown, size: 18),
            label: const Text('Drop-off'),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        final detail = detailController.text.trim();
        await _dataService.sendTrafficAlert(result, detail: detail.isNotEmpty ? detail : null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Traffic alert sent to all owners for ${result == 'pickup' ? 'pickup' : 'drop-off'}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to send traffic alert: $e')));
        }
      }
    }
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
                  icon: PhosphorIcon(PhosphorIconsDuotone.bell),
                  tooltip: 'Date Change Requests',
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => StaffNotificationsScreen(canManageRequests: _canManageRequests)),
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
              icon: PhosphorIcon(PhosphorIconsDuotone.plus),
              label: const Text('Add Dog'),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
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
            icon: PhosphorIcon(PhosphorIconsDuotone.pawPrint),
            label: _isStaff ? 'All Dogs' : (_allDogs.length == 1 ? _allDogs.first.name : 'My Dogs'),
          ),
          BottomNavigationBarItem(
            icon: PhosphorIcon(PhosphorIconsDuotone.images),
            label: 'Feed',
          ),
          if (_isStaff)
            BottomNavigationBarItem(
              icon: PhosphorIcon(PhosphorIconsDuotone.squaresFour),
              label: "Dashboard",
            ),
        ],
      ),
      body: _isOffline
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
                      isStaff: _isStaff,
                      myUserId: _myUserId,
                      initialStaffId: _dogGroupsStaffFilter,
                      onSwitchToFeed: () => setState(() => _currentIndex = 1),
                    ),
    ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: AppColors.primary),
            child: Center(
              child: Image.asset('assets/logo.png', height: 48),
            ),
          ),
          ListTile(
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                PhosphorIcon(PhosphorIconsDuotone.chats),
                if (_unresolvedQueryCount > 0)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                      child: Text(
                        '$_unresolvedQueryCount',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            title: const Text('Contact Staff'),
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
          if (_isStaff && _canViewInquiries)
            ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  PhosphorIcon(PhosphorIconsDuotone.envelope),
                  if (_unreadInquiryCount > 0)
                    Positioned(
                      right: -6,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                        child: Text(
                          '$_unreadInquiryCount',
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              title: const Text('Website Inquiries'),
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
              leading: PhosphorIcon(PhosphorIconsDuotone.path),
              title: const Text('Traffic Alert'),
              onTap: () {
                Navigator.pop(context);
                _showTrafficAlertDialog();
              },
            ),
          if (_isStaff)
            ListTile(
              leading: PhosphorIcon(PhosphorIconsDuotone.clock),
              title: const Text('My Availability'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => StaffAvailabilityScreen(canAssignDogs: _canAssignDogs, canApproveTimeoff: _canApproveTimeoff),
                  ),
                );
              },
            ),
          ListTile(
            leading: PhosphorIcon(PhosphorIconsDuotone.calendarX),
            title: const Text('Holidays & Closures'),
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
          const Divider(),
          ListTile(
            leading: PhosphorIcon(PhosphorIconsDuotone.user),
            title: const Text('Profile'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
          if (_appVersion.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _appVersion,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
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
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PhosphorIcon(PhosphorIconsDuotone.pawPrint, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No dogs yet!',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            if (_isStaff)
              const Text('Tap the button below to add your first dog.')
            else ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Please contact staff to request your dog is attached to your profile.',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => QueryListScreen(isStaff: _isStaff),
                    ),
                  );
                },
                icon: PhosphorIcon(PhosphorIconsDuotone.headset),
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
                prefixIcon: PhosphorIcon(PhosphorIconsDuotone.magnifyingGlass),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: PhosphorIcon(PhosphorIconsDuotone.x),
                        onPressed: () {
                          _searchController.clear();
                          _filterDogs('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
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
              : RefreshIndicator(
                  onRefresh: () async => _loadDogs(),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: _filteredDogs.length,
                    itemBuilder: (context, index) {
                      final dog = _filteredDogs[index];
                      return Card(
                        elevation: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        child: InkWell(
                          onTap: () async {
                            final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DogHomeScreen(dog: dog, isStaff: _isStaff),
                              ),
                            );
                            if (result == 'deleted') _refresh();
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (dog.profileImageUrl != null)
                                ClipRRect(
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
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
                                        SizedBox(height: 200, child: Center(child: PhosphorIcon(PhosphorIconsDuotone.warningCircle))),
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

