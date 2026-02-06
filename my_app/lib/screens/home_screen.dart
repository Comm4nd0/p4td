import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/dog.dart';
import '../models/user_profile.dart';
import '../models/date_change_request.dart';
import '../services/data_service.dart';
import '../services/auth_service.dart';
import 'dog_home_screen.dart';
import 'login_screen.dart';
import 'profile_screen.dart';
import 'add_dog_screen.dart';
import 'staff_notifications_screen.dart';
import 'feed_screen.dart';
import 'request_boarding_screen.dart';
import 'boarding_request_list_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DataService _dataService = ApiDataService();
  final AuthService _authService = AuthService();
  late Future<List<Dog>> _dogsFuture;
  bool _isStaff = false;
  int _currentIndex = 1;
  int _pendingRequestCount = 0;

  @override
  void initState() {
    super.initState();
    _loadDogs();
    _checkStaffStatus();
  }

  void _loadDogs() {
    _dogsFuture = _dataService.getDogs();
  }

  Future<void> _checkStaffStatus() async {
    try {
      final profile = await _dataService.getProfile();
      if (mounted) {
        setState(() => _isStaff = profile.isStaff);
        // Load pending requests count after setting staff status
        if (profile.isStaff) {
          await _loadPendingRequestCount();
        }
      }
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _loadPendingRequestCount() async {
    if (!_isStaff) return;
    try {
      final requests = await _dataService.getDateChangeRequests();
      final pendingCount = requests.where((r) => r.status == RequestStatus.pending).length;
      if (mounted) {
        setState(() => _pendingRequestCount = pendingCount);
      }
    } catch (e) {
      // Ignore errors
    }
  }

  void _refresh() {
    setState(() {
      _loadDogs();
    });
    _loadPendingRequestCount();
  }

  Future<void> _logout() async {
    await _authService.logout();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/logo.png', height: 32),
            const SizedBox(width: 8),
            Text(_currentIndex == 0 ? 'My Dogs' : 'Feed'),
          ],
        ),
        actions: [
          if (_isStaff)
            Stack(
              children: [
                IconButton(
                  icon: const Icon(Icons.notifications),
                  tooltip: 'Date Change Requests',
                  onPressed: () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const StaffNotificationsScreen()),
                    );
                    // Refresh count when returning from notifications screen
                    if (result == true) {
                      _loadPendingRequestCount();
                    }
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
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0
          ? FloatingActionButton.extended(
              onPressed: _addDog,
              icon: const Icon(Icons.add),
              label: const Text('Add Dog'),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.pets),
            label: 'My Dogs',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.photo_library),
            label: 'Feed',
          ),
        ],
      ),
      body: _currentIndex == 0 ? _buildDogsView() : FeedScreen(isStaff: _isStaff),
    );
  }

  Widget _buildDogsView() {
    return FutureBuilder<List<Dog>>(
      future: _dogsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
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

        final dogs = snapshot.data!;
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: dogs.length,
            itemBuilder: (context, index) {
              final dog = dogs[index];
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
        );
      },
    );
  }
}

