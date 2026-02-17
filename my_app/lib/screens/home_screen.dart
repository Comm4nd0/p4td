import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/dog.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';
import '../services/notification_service.dart';
import 'dog_home_screen.dart';
import 'profile_screen.dart';
import 'add_dog_screen.dart';
import 'staff_notifications_screen.dart';
import 'feed_screen.dart';
import 'request_boarding_screen.dart';
import 'boarding_request_list_screen.dart';
import 'staff_daily_assignments_screen.dart';
import 'query_list_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DataService _dataService = ApiDataService();
  // final AuthService _authService = AuthService(); // Removed unused
  final NotificationService _notificationService = NotificationService();
  
  List<Dog> _allDogs = [];
  List<Dog> _filteredDogs = [];
  bool _loadingDogs = true;
  final TextEditingController _searchController = TextEditingController();

  bool _isStaff = false;
  bool _canAssignDogs = false;
  bool _canAddFeedMedia = false;
  bool _canManageRequests = false;
  bool _canReplyQueries = false;
  int _currentIndex = 1;
  int _pendingRequestCount = 0;
  int _unresolvedQueryCount = 0;
  final GlobalKey<StaffDailyAssignmentsScreenState> _assignmentsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadDogs();
    _checkStaffStatus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadDogs() async {
    if (!mounted) return;
    setState(() => _loadingDogs = true);
    
    try {
      final dogs = await _dataService.getDogs();
      // Alphabetical sort
      dogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      
      if (mounted) {
        setState(() {
          _allDogs = dogs;
          _filteredDogs = dogs;
          _loadingDogs = false;
          // Re-apply filter if search text exists
          if (_searchController.text.isNotEmpty) {
            _filterDogs(_searchController.text);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingDogs = false);
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('Failed to load dogs: $e')),
        );
      }
    }
  }

  void _filterDogs(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredDogs = _allDogs;
      } else {
        _filteredDogs = _allDogs
            .where((dog) => dog.name.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
  }

  Future<void> _checkStaffStatus() async {
    try {
      final profile = await _dataService.getProfile();
      if (mounted) {
        setState(() {
          _isStaff = profile.isStaff;
          _canAssignDogs = profile.canAssignDogs;
          _canAddFeedMedia = profile.canAddFeedMedia;
          _canManageRequests = profile.canManageRequests;
          _canReplyQueries = profile.canReplyQueries;
        });
        // Load pending requests count and subscribe to notifications
        if (profile.isStaff) {
          await _loadPendingRequestCount();
          await _notificationService.subscribeToTopic('staff_notifications');
        } else {
          await _notificationService.unsubscribeFromTopic('staff_notifications');
        }
        await _loadUnresolvedQueryCount();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to check staff status: $e'), backgroundColor: Colors.red),
        );
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

  void _refresh() {
    setState(() {
      _loadDogs();
    });
    _loadPendingRequestCount();
    _loadUnresolvedQueryCount();
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
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.traffic, color: Colors.orange),
            SizedBox(width: 8),
            Text('Traffic Alert'),
          ],
        ),
        content: const Text(
          'Send a traffic delay notification to all owners with dogs on your route today. '
          'Which service is affected?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'pickup'),
            icon: const Icon(Icons.arrow_upward, size: 18),
            label: const Text('Pickup'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'dropoff'),
            icon: const Icon(Icons.arrow_downward, size: 18),
            label: const Text('Drop-off'),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        await _dataService.sendTrafficAlert(result);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Traffic alert sent to all owners for ${result == 'pickup' ? 'pickup' : 'drop-off'}',
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
    return Scaffold(
      appBar: AppBar(
        title: Image.asset('assets/logo.png', height: 32),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.question_answer),
                tooltip: 'Support Queries',
                onPressed: () async {
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
              if (_unresolvedQueryCount > 0)
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
                        '$_unresolvedQueryCount',
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
                    // Refresh count when returning from notifications screen
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
          if (_isStaff)
            IconButton(
              icon: const Icon(Icons.traffic),
              tooltip: 'Traffic Alert',
              onPressed: _showTrafficAlertDialog,
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.night_shelter),
            onSelected: (value) {
              if (value == 'request') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RequestBoardingScreen()),
                );
              } else if (value == 'list') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BoardingRequestListScreen()),
                );
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'request',
                child: Row(
                   children: [
                     Icon(Icons.add, color: Colors.black54),
                     SizedBox(width: 8),
                     Text('Request Boarding'),
                   ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'list',
                 child: Row(
                   children: [
                     Icon(Icons.list, color: Colors.black54),
                     SizedBox(width: 8),
                     Text('My Requests'),
                   ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0 && _isStaff
          ? FloatingActionButton.extended(
              onPressed: _addDog,
              icon: const Icon(Icons.add),
              label: const Text('Add Dog'),
            )
          : _currentIndex == 2 && _isStaff
              ? FloatingActionButton.extended(
                  onPressed: () => _assignmentsKey.currentState?.assignDogs(),
                  icon: const Icon(Icons.add),
                  label: const Text('Assign Dogs'),
                )
              : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          // If non-staff user with a single dog taps "My Dogs", go straight to dog profile
          if (index == 0 && !_isStaff && !_loadingDogs && _allDogs.length == 1) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DogHomeScreen(dog: _allDogs.first, isStaff: false),
              ),
            );
            return;
          }
          setState(() => _currentIndex = index);
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
              label: "Dog Groups",
            ),
        ],
      ),
      body: _currentIndex == 0
          ? _buildDogsView()
          : _currentIndex == 1
              ? FeedScreen(isStaff: _isStaff, canAddFeedMedia: _canAddFeedMedia)
              : StaffDailyAssignmentsScreen(key: _assignmentsKey, canAssignDogs: _canAssignDogs),
    );
  }

  Widget _buildDogsView() {
    if (_loadingDogs) {
      return const Center(child: CircularProgressIndicator());
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
            const Text('Tap the button below to add your first dog.'),
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
                hintText: 'Search dogs...',
                prefixIcon: const Icon(Icons.search),
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
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DogHomeScreen(dog: dog, isStaff: _isStaff),
                              ),
                            );
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

