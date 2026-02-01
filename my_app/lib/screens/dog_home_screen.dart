import 'package:flutter/material.dart';
import '../models/dog.dart';
import 'bookings_screen.dart';
import 'gallery_screen.dart';
import 'edit_dog_screen.dart'; // Import EditDogScreen

class DogHomeScreen extends StatefulWidget {
  final Dog dog;

  const DogHomeScreen({super.key, required this.dog});

  @override
  State<DogHomeScreen> createState() => _DogHomeScreenState();
}

class _DogHomeScreenState extends State<DogHomeScreen> {
  int _currentIndex = 0;
  late Dog _dog;

  @override
  void initState() {
    super.initState();
    _dog = widget.dog;
  }

  @override
  Widget build(BuildContext context) {
    // Re-create screens with current dog data
    final screens = [
      BookingsScreen(dogId: _dog.id),
      GalleryScreen(dogId: _dog.id),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_dog.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => EditDogScreen(dog: _dog),
                ),
              );
              // In a real app we would reload the dog here.
              // For now, let's just pop back if we want to refresh via HomeScreen
              // Or better, we should fetch the dog again.
              // But DogHomeScreen takes Dog as Argument. 
              // Simplest for now: If updated, show message or pop?
              // Ideally: fetch updated dog from API or pass it back.
              // Let's assume we navigate back to home to see changes if needed 
              // or just rely on next fetch.
              // Actually, updating local _dog state would be nice if EditDogScreen returned it.
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).primaryColor.withOpacity(0.1),
            child: Column(
              children: [
                Row(
                  children: [
                    Hero(
                      tag: 'dog_image_${_dog.id}',
                      child: CircleAvatar(
                        radius: 40,
                        backgroundImage: _dog.profileImageUrl != null 
                            ? NetworkImage(_dog.profileImageUrl!) 
                            : null,
                        child: _dog.profileImageUrl == null 
                            ? const Icon(Icons.pets, size: 40) 
                            : null,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _dog.name,
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          Text(
                            _dog.breed,
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: Colors.grey[700],
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_dog.daysInDaycare.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Daycare Schedule',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[700],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: _dog.daysInDaycare.map((day) {
                          return Chip(
                            label: Text(
                              day.displayName.substring(0, 3),
                              style: const TextStyle(fontSize: 12),
                            ),
                            backgroundColor: Colors.blue[100],
                            labelStyle: const TextStyle(
                              color: Colors.blue,
                              fontWeight: FontWeight.bold,
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: screens[_currentIndex]),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_today),
            label: 'Bookings',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.photo_library),
            label: 'Gallery',
          ),
        ],
      ),
    );
  }
}
