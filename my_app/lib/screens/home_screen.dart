import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:upgrader/upgrader.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../models/daily_dog_assignment.dart';
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
import 'request_boarding_screen.dart';
import 'boarding_request_list_screen.dart';
import 'staff_daily_assignments_screen.dart';
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
  final GlobalKey<StaffDailyAssignmentsScreenState> _assignmentsKey = GlobalKey();
  bool _initialRouteHandled = false;

  // Staff Working Today data
  List<DailyDogAssignment> _todayAssignments = [];
  // Boarding Tonight data
  List<BoardingRequest> _boardingTonight = [];
  // Staff filter for Pickups tab navigation
  int? _dogGroupsStaffFilter;
  // Track upload progress for large batches
  int _uploadedCount = 0;
  // Feed stats for today
  int _todayPhotos = 0;
  int _todayVideos = 0;

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
            setState(() => _currentIndex = 3);
          }
          await _loadPendingRequestCount();
          await _notificationService.subscribeToTopic('staff_notifications');
          _loadStaffWorkingToday();
          _loadBoardingTonight();
          _loadFeedTodayStats();
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

  Future<void> _loadStaffWorkingToday() async {
    if (!_isStaff) return;
    try {
      final assignments = await _dataService.getTodayAssignments();
      if (mounted) {
        setState(() => _todayAssignments = assignments);
      }
    } catch (_) {}
  }

  Future<void> _loadFeedTodayStats() async {
    try {
      final stats = await _dataService.getFeedTodayStats();
      if (mounted) {
        setState(() {
          _todayPhotos = stats['photos'] ?? 0;
          _todayVideos = stats['videos'] ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadBoardingTonight() async {
    try {
      final requests = await _dataService.getBoardingRequests();
      final today = DateTime.now();
      final tonight = DateTime(today.year, today.month, today.day);
      if (mounted) {
        setState(() {
          _boardingTonight = requests.where((r) =>
            r.status == BoardingRequestStatus.approved &&
            !r.startDate.isAfter(tonight) &&
            r.endDate.isAfter(tonight)
          ).toList();
        });
      }
    } catch (_) {}
  }

  void _refresh() {
    _loadDogs();
    _loadPendingRequestCount();
    _loadUnresolvedQueryCount();
    if (_canViewInquiries) _loadUnreadInquiryCount();
    _loadStaffWorkingToday();
    _loadBoardingTonight();
    _loadFeedTodayStats();
  }

  void _navigateToDogGroups({int? staffId}) {
    setState(() {
      _dogGroupsStaffFilter = staffId;
      _currentIndex = 2;
    });
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
    // Fetch staff's assignments for today to show dog selection
    List<DailyDogAssignment> myAssignments = [];
    try {
      myAssignments = await _dataService.getMyAssignments();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load your assignments: $e'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    if (myAssignments.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have no dogs assigned today.')),
        );
      }
      return;
    }

    // De-duplicate by dogId (a dog might appear once but just in case)
    final uniqueDogs = <int, DailyDogAssignment>{};
    for (final a in myAssignments) {
      uniqueDogs.putIfAbsent(a.dogId, () => a);
    }
    final dogList = uniqueDogs.values.toList();

    // All selected by default
    final selectedDogIds = <int>{...dogList.map((d) => d.dogId)};
    final detailController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.traffic, color: Colors.orange),
              SizedBox(width: 8),
              Text('Traffic Alert'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Select which dogs\' owners to notify:',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setDialogState(() {
                        selectedDogIds.addAll(dogList.map((d) => d.dogId));
                      }),
                      child: const Text('Select All'),
                    ),
                    TextButton(
                      onPressed: () => setDialogState(() => selectedDogIds.clear()),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.3,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: dogList.length,
                    itemBuilder: (context, index) {
                      final assignment = dogList[index];
                      final isSelected = selectedDogIds.contains(assignment.dogId);
                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (checked) {
                          setDialogState(() {
                            if (checked == true) {
                              selectedDogIds.add(assignment.dogId);
                            } else {
                              selectedDogIds.remove(assignment.dogId);
                            }
                          });
                        },
                        title: Text(assignment.dogName),
                        subtitle: Text(assignment.ownerName),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                      );
                    },
                  ),
                ),
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
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: selectedDogIds.isEmpty ? null : () => Navigator.pop(context, 'pickup'),
              icon: const Icon(Icons.arrow_upward, size: 18),
              label: const Text('Pickup'),
            ),
            FilledButton.icon(
              onPressed: selectedDogIds.isEmpty ? null : () => Navigator.pop(context, 'dropoff'),
              icon: const Icon(Icons.arrow_downward, size: 18),
              label: const Text('Drop-off'),
            ),
          ],
        ),
      ),
    );

    if (result != null && selectedDogIds.isNotEmpty) {
      try {
        final detail = detailController.text.trim();
        await _dataService.sendTrafficAlert(
          result,
          detail: detail.isNotEmpty ? detail : null,
          dogIds: selectedDogIds.toList(),
        );
        if (mounted) {
          final count = selectedDogIds.length;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Traffic alert sent to $count owner${count == 1 ? '' : 's'} for ${result == 'pickup' ? 'pickup' : 'drop-off'}',
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send traffic alert: $e')),
          );
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
                  icon: const Icon(Icons.notifications),
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
              icon: const Icon(Icons.add),
              label: const Text('Add Dog'),
            )
          : _currentIndex == 2 && _canAssignDogs
              ? FloatingActionButton.extended(
                  heroTag: 'assignDogsFab',
                  onPressed: () => _assignmentsKey.currentState?.assignDogs(),
                  icon: const Icon(Icons.add),
                  label: const Text('Assign Dogs'),
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
            icon: const Icon(Icons.pets),
            label: _isStaff ? 'All Dogs' : (_allDogs.length == 1 ? _allDogs.first.name : 'My Dogs'),
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.photo_library),
            label: 'Feed',
          ),
          if (_isStaff)
            const BottomNavigationBarItem(
              icon: Icon(Icons.today),
              label: "Pickups",
            ),
          if (_isStaff)
            const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard),
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
                  : _currentIndex == 2
                      ? StaffDailyAssignmentsScreen(key: _assignmentsKey, canAssignDogs: _canAssignDogs, initialStaffId: _dogGroupsStaffFilter)
                      : _buildDashboardView(),
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
                const Icon(Icons.question_answer),
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
                  const Icon(Icons.mail_outline),
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
              leading: const Icon(Icons.traffic),
              title: const Text('Traffic Alert'),
              onTap: () {
                Navigator.pop(context);
                _showTrafficAlertDialog();
              },
            ),
          if (_isStaff)
            ListTile(
              leading: const Icon(Icons.schedule),
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
            leading: const Icon(Icons.event_busy),
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
            leading: const Icon(Icons.person),
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

  Widget _buildStaffDashboard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Dashboard', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _DashboardCard(
                  icon: Icons.pending_actions,
                  label: 'Pending\nRequests',
                  count: _pendingRequestCount,
                  color: _pendingRequestCount > 0 ? AppColors.warning : null,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StaffNotificationsScreen(canManageRequests: _canManageRequests),
                      ),
                    );
                    _loadPendingRequestCount();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _DashboardCard(
                  icon: Icons.question_answer,
                  label: 'Unresolved\nQueries',
                  count: _unresolvedQueryCount,
                  color: _unresolvedQueryCount > 0 ? AppColors.info : null,
                  onTap: () async {
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
              ),
              if (_canViewInquiries) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _DashboardCard(
                    icon: Icons.mail_outline,
                    label: 'Unread\nInquiries',
                    count: _unreadInquiryCount,
                    color: _unreadInquiryCount > 0 ? AppColors.error : null,
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const InquiryListScreen()),
                      );
                      _loadUnreadInquiryCount();
                    },
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Today's Feed Uploads
          Row(
            children: [
              Expanded(
                child: _DashboardCard(
                  icon: Icons.photo_camera,
                  label: 'Photos\nToday',
                  count: _todayPhotos,
                  onTap: () {
                    setState(() => _currentIndex = 1);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _DashboardCard(
                  icon: Icons.videocam,
                  label: 'Videos\nToday',
                  count: _todayVideos,
                  onTap: () {
                    setState(() => _currentIndex = 1);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Quick action buttons
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.traffic, size: 18),
                label: const Text('Traffic Alert'),
                onPressed: _showTrafficAlertDialog,
              ),
              ActionChip(
                avatar: const Icon(Icons.upload, size: 18),
                label: const Text('Upload to Feed'),
                onPressed: _uploadMediaFromDashboard,
              ),
              ActionChip(
                avatar: const Icon(Icons.calendar_month, size: 18),
                label: const Text('Boarding Calendar'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BoardingRequestListScreen()),
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          // Staff Working Today
          if (_canAssignDogs && _todayAssignments.isNotEmpty) ...[
            Text('Staff Working Today', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _buildStaffWorkingToday(),
            const Divider(height: 16),
          ],
          // Boarding Tonight
          if (_boardingTonight.isNotEmpty) ...[
            Text('Boarding Tonight', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _buildBoardingTonight(),
            const Divider(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildStaffWorkingToday() {
    // Group assignments by staff member
    final Map<int, _StaffSummary> staffMap = {};
    for (final a in _todayAssignments) {
      staffMap.putIfAbsent(a.staffMemberId, () => _StaffSummary(a.staffMemberId, a.staffMemberName));
      staffMap[a.staffMemberId]!.dogCount++;
    }
    final staffList = staffMap.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: staffList.map((staff) {
        return ActionChip(
          avatar: CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.primary,
            child: Text(
              '${staff.dogCount}',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          label: Text(staff.name),
          onPressed: () => _navigateToDogGroups(staffId: staff.id),
        );
      }).toList(),
    );
  }

  Widget _buildBoardingTonight() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _boardingTonight.map((request) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              const Icon(Icons.night_shelter, size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${request.dogNames.join(", ")} (${request.ownerName})',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Future<void> _uploadMediaFromDashboard() async {
    final picker = ImagePicker();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.camera_alt), title: const Text('Take Photo'), onTap: () => Navigator.pop(context, 'camera_photo')),
            ListTile(leading: const Icon(Icons.photo_library), title: const Text('Choose Photo'), onTap: () => Navigator.pop(context, 'gallery_photo')),
            const Divider(),
            ListTile(leading: const Icon(Icons.videocam), title: const Text('Record Video'), onTap: () => Navigator.pop(context, 'camera_video')),
            ListTile(leading: const Icon(Icons.video_library), title: const Text('Choose Video'), onTap: () => Navigator.pop(context, 'gallery_video')),
            const Divider(),
            ListTile(leading: const Icon(Icons.library_add), title: const Text('Upload Multiple'), onTap: () => Navigator.pop(context, 'multiple')),
          ],
        ),
      ),
    );
    if (choice == null) return;

    if (choice == 'multiple') {
      final files = await picker.pickMultipleMedia();
      if (files.isEmpty) return;
      final caption = await _showDashboardCaptionDialog();
      if (caption == null) return;
      final progress = ValueNotifier<String>('Preparing 0/${files.length}...');
      final total = files.length;
      showDialog(context: context, barrierDismissible: false, builder: (_) => PopScope(canPop: false, child: ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (context, status, _) => AlertDialog(content: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(), const SizedBox(height: 16), Text(status),
          const SizedBox(height: 8), LinearProgressIndicator(value: total > 0 ? (_uploadedCount / total) : 0),
        ])),
      )));
      _uploadedCount = 0;
      int failedCount = 0;
      try {
        for (int i = 0; i < files.length; i++) {
          final file = files[i];
          progress.value = 'Processing ${i + 1}/$total...';
          try {
            final bytes = await file.readAsBytes();
            final ext = file.name.toLowerCase();
            final isVideo = ext.endsWith('.mp4') || ext.endsWith('.mov') || ext.endsWith('.avi');
            progress.value = 'Uploading ${i + 1}/$total...';
            await _dataService.uploadGroupMedia(
              fileBytes: bytes,
              fileName: file.name,
              isVideo: isVideo,
              caption: caption.isEmpty ? null : caption,
            );
            _uploadedCount = i + 1;
          } catch (e) {
            failedCount++;
            // Continue with remaining files
          }
        }
        if (mounted) {
          Navigator.pop(context);
          final successCount = total - failedCount;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(failedCount > 0
              ? 'Uploaded $successCount/$total files ($failedCount failed)'
              : 'Successfully uploaded $total file${total == 1 ? '' : 's'}!'),
            backgroundColor: failedCount > 0 ? Colors.orange : Colors.green,
          ));
          _loadFeedTodayStats();
        }
      } catch (e) {
        if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red)); }
      }
      return;
    }

    XFile? file;
    final isVideo = choice.contains('video');
    final source = choice.contains('camera') ? ImageSource.camera : ImageSource.gallery;
    if (isVideo) { file = await picker.pickVideo(source: source); } else { file = await picker.pickImage(source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 85); }
    if (file == null) return;
    final caption = await _showDashboardCaptionDialog();
    if (caption == null) return;
    try {
      showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Text('Uploading...')])));
      final bytes = await file.readAsBytes();
      await _dataService.uploadGroupMedia(fileBytes: bytes, fileName: file.name, isVideo: isVideo, caption: caption.isEmpty ? null : caption);
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload successful!'), backgroundColor: Colors.green)); _loadFeedTodayStats(); }
    } catch (e) {
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red)); }
    }
  }

  Future<String?> _showDashboardCaptionDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Caption'),
        content: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Write a caption (optional)', border: OutlineInputBorder()), maxLines: 3),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Upload')),
        ],
      ),
    );
  }

  Widget _buildDashboardView() {
    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Today's Overview
          Text("Today's Overview", style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _OverviewCard(
                icon: Icons.pets,
                value: '${_todayAssignments.map((a) => a.dogId).toSet().length}',
                label: 'Dogs Today',
                color: AppColors.primary,
                onTap: () => _navigateToDogGroups(),
              )),
              const SizedBox(width: 8),
              Expanded(child: _OverviewCard(
                icon: Icons.list_alt,
                value: '${_allDogs.length}',
                label: 'Total Dogs',
                color: AppColors.primary,
                onTap: () => setState(() => _currentIndex = 0),
              )),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _OverviewCard(
                icon: Icons.person,
                value: '${_myUserId != null ? _todayAssignments.where((a) => a.staffMemberId == _myUserId).length : 0}',
                label: 'My Dogs Today',
                color: AppColors.primary,
                onTap: _myUserId != null ? () => _navigateToDogGroups(staffId: _myUserId) : null,
              )),
              const SizedBox(width: 8),
              Expanded(child: _OverviewCard(
                icon: Icons.assignment_turned_in,
                value: '${_todayAssignments.length}',
                label: 'Total Assigned',
                color: AppColors.info,
                onTap: () => _navigateToDogGroups(),
              )),
            ],
          ),
          const SizedBox(height: 24),

          // Staff Working Today
          if (_canAssignDogs && _todayAssignments.isNotEmpty) ...[
            Text('Staff Working Today', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ..._buildStaffWorkingTodayCards(),
            const SizedBox(height: 24),
          ],

          // Boarding Today
          Text('Boarding Today', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (_boardingTonight.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text('No boarding today', style: TextStyle(color: Colors.grey[500])),
                ),
              ),
            )
          else
            _buildBoardingTonight(),
          const SizedBox(height: 24),

          // Action Items
          Text('Action Items', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _ActionItemTile(
            icon: Icons.pending_actions,
            label: 'Pending Requests',
            count: _pendingRequestCount,
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(
                builder: (_) => StaffNotificationsScreen(canManageRequests: _canManageRequests),
              ));
              _loadPendingRequestCount();
            },
          ),
          const SizedBox(height: 8),
          _ActionItemTile(
            icon: Icons.question_answer,
            label: 'Unresolved Queries',
            count: _unresolvedQueryCount,
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(
                builder: (_) => QueryListScreen(isStaff: _isStaff, canReplyQueries: _canReplyQueries),
              ));
              _loadUnresolvedQueryCount();
            },
          ),
          if (_canViewInquiries) ...[
            const SizedBox(height: 8),
            _ActionItemTile(
              icon: Icons.mail_outline,
              label: 'Unread Inquiries',
              count: _unreadInquiryCount,
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const InquiryListScreen()));
                _loadUnreadInquiryCount();
              },
            ),
          ],
          const SizedBox(height: 8),
          _ActionItemTile(
            icon: Icons.night_shelter,
            label: 'Boarding Requests',
            count: _boardingTonight.length,
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const BoardingRequestListScreen(),
            )),
          ),
          const SizedBox(height: 24),

          // Quick Actions
          Text('Quick Actions', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.upload, size: 18),
                label: const Text('Upload to Feed'),
                onPressed: _uploadMediaFromDashboard,
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildStaffWorkingTodayCards() {
    final Map<int, _StaffSummary> staffMap = {};
    for (final a in _todayAssignments) {
      staffMap.putIfAbsent(a.staffMemberId, () => _StaffSummary(a.staffMemberId, a.staffMemberName));
      staffMap[a.staffMemberId]!.dogCount++;
    }
    final staffList = staffMap.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return staffList.map((staff) {
      return Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: AppColors.primary,
            child: Text(staff.name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          title: Text(staff.name),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Chip(
                label: Text('${staff.dogCount} dog${staff.dogCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
                backgroundColor: AppColors.primary,
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => _navigateToDogGroups(staffId: staff.id),
        ),
      );
    }).toList();
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
            Icon(Icons.pets, size: 64, color: Colors.grey[400]),
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
                icon: const Icon(Icons.support_agent),
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
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
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
                                        const SizedBox(height: 200, child: Center(child: Icon(Icons.error))),
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

/// Overview stat card for the dashboard.
class _OverviewCard extends StatefulWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _OverviewCard({required this.icon, required this.value, required this.label, required this.color, this.onTap});

  @override
  State<_OverviewCard> createState() => _OverviewCardState();
}

class _OverviewCardState extends State<_OverviewCard> {
  bool _pressed = false;

  void _handleTap() async {
    if (widget.onTap == null) return;
    setState(() => _pressed = true);
    await Future.delayed(const Duration(milliseconds: 120));
    if (mounted) setState(() => _pressed = false);
    await Future.delayed(const Duration(milliseconds: 60));
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onTap != null ? (_) => setState(() => _pressed = true) : null,
      onTapUp: widget.onTap != null ? (_) {} : null,
      onTapCancel: widget.onTap != null ? () => setState(() => _pressed = false) : null,
      onTap: _handleTap,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(widget.icon, color: widget.color, size: 20),
                const SizedBox(height: 8),
                Text(widget.value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                Text(widget.label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Action item row tile for the dashboard.
class _ActionItemTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  const _ActionItemTile({required this.icon, required this.label, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: CircleAvatar(
          radius: 14,
          backgroundColor: Colors.grey[700],
          child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
        onTap: onTap,
      ),
    );
  }
}

/// Simple data holder for staff summary on the dashboard.
class _StaffSummary {
  final int id;
  final String name;
  int dogCount;
  _StaffSummary(this.id, this.name) : dogCount = 0;
}

/// Compact card for the staff dashboard showing a metric count.
class _DashboardCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color? color;
  final VoidCallback onTap;

  const _DashboardCard({
    required this.icon,
    required this.label,
    required this.count,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardColor = color ?? theme.colorScheme.outline;

    return Card(
      elevation: 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              Icon(icon, color: cardColor, size: 24),
              const SizedBox(height: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: count > 0 ? cardColor : theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

