import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/dog.dart';
import 'gallery_screen.dart';
import 'edit_dog_screen.dart';

class DogHomeScreen extends StatefulWidget {
  final Dog dog;

  const DogHomeScreen({super.key, required this.dog});

  @override
  State<DogHomeScreen> createState() => _DogHomeScreenState();
}

class _DogHomeScreenState extends State<DogHomeScreen> {
  late Dog _dog;

  @override
  void initState() {
    super.initState();
    _dog = widget.dog;
  }

  List<DateTime> _getUpcomingDaycareDates() {
    final List<DateTime> dates = [];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final threeMonthsLater = DateTime(now.year, now.month + 3, now.day);

    final dayNumbers = _dog.daysInDaycare.map((d) => d.dayNumber).toSet();

    var current = today;
    while (current.isBefore(threeMonthsLater)) {
      if (dayNumbers.contains(current.weekday)) {
        dates.add(current);
      }
      current = current.add(const Duration(days: 1));
    }

    return dates;
  }

  bool _isConfirmed(DateTime date) {
    final now = DateTime.now();
    final oneMonthLater = DateTime(now.year, now.month + 1, now.day);
    return date.isBefore(oneMonthLater);
  }

  void _showDateChangeRequest(DateTime date) {
    final isConfirmed = _isConfirmed(date);
    final formattedDate = DateFormat('EEEE, d MMMM yyyy').format(date);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request Date Change'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Date: $formattedDate'),
            const SizedBox(height: 16),
            if (isConfirmed) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange[800]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This date is within 1 month. You will still be charged for this day.',
                        style: TextStyle(color: Colors.orange[800]),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Text('Would you like to request a change for this date?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Date change request submitted')),
              );
            },
            child: const Text('Request Change'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final upcomingDates = _getUpcomingDaycareDates();

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
                        'Upcoming Dates',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[700],
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 80,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: upcomingDates.length,
                          itemBuilder: (context, index) {
                            final date = upcomingDates[index];
                            final isConfirmed = _isConfirmed(date);
                            return GestureDetector(
                              onTap: () => _showDateChangeRequest(date),
                              child: Container(
                                width: 60,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: isConfirmed ? Colors.green[100] : Colors.grey[200],
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isConfirmed ? Colors.green : Colors.grey[400]!,
                                    width: 1,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      DateFormat('E').format(date),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isConfirmed ? Colors.green[800] : Colors.grey[600],
                                      ),
                                    ),
                                    Text(
                                      DateFormat('d').format(date),
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: isConfirmed ? Colors.green[800] : Colors.grey[600],
                                      ),
                                    ),
                                    Text(
                                      DateFormat('MMM').format(date),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isConfirmed ? Colors.green[700] : Colors.grey[500],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: GalleryScreen(dogId: _dog.id)),
        ],
      ),
    );
  }
}
