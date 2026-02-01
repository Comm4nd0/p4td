import 'package:flutter/material.dart';
import '../models/dog.dart';
import '../models/user_profile.dart';
import '../services/data_service.dart';
import '../services/auth_service.dart';
import 'dog_home_screen.dart';
import 'login_screen.dart';
import 'profile_screen.dart';
import 'add_dog_screen.dart';
import 'staff_notifications_screen.dart';
import 'feed_screen.dart';

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
  int _currentIndex = 0;

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
      }
    } catch (e) {
      // Ignore errors
    }
  }

  void _refresh() {
    setState(() {
      _loadDogs();
    });
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
            IconButton(
              icon: const Icon(Icons.notifications),
              tooltip: 'Date Change Requests',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StaffNotificationsScreen()),
                );
              },
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
                          child: Image.network(
                            dog.profileImageUrl!,
                            height: 200,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
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

