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
              final updatedDog = await Navigator.push<Dog>(
                context,
                MaterialPageRoute(
                  builder: (_) => EditDogScreen(dog: _dog),
                ),
              );
              if (updatedDog != null) {
                setState(() {
                  _dog = updatedDog;
                });
              }
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
                      child: Text(
                        _dog.name,
                        style: Theme.of(context).textTheme.headlineMedium,
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
                        children: ([..._dog.daysInDaycare]..sort((a, b) => a.dayNumber.compareTo(b.dayNumber))).map((day) {
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
