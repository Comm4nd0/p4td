import 'package:flutter/material.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../services/auth_service.dart';
import 'dog_home_screen.dart';
import 'login_screen.dart';
import 'profile_screen.dart';
import 'add_dog_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DataService _dataService = ApiDataService(); 
  final AuthService _authService = AuthService();
  late Future<List<Dog>> _dogsFuture;

  @override
  void initState() {
    super.initState();
    _loadDogs();
  }

  void _loadDogs() {
    _dogsFuture = _dataService.getDogs();
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
            const Text('Paws 4 Thought'),
          ],
        ),
        actions: [
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDog,
        icon: const Icon(Icons.add),
        label: const Text('Add Dog'),
      ),
      body: FutureBuilder<List<Dog>>(
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
                          builder: (_) => DogHomeScreen(dog: dog),
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                dog.name,
                                style: Theme.of(context).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                dog.breed,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
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
      ),
    );
  }
}

