import 'package:flutter/material.dart';
import '../models/dog.dart';
import '../services/data_service.dart';

class RequestBoardingScreen extends StatefulWidget {
  const RequestBoardingScreen({super.key});

  @override
  State<RequestBoardingScreen> createState() => _RequestBoardingScreenState();
}

class _RequestBoardingScreenState extends State<RequestBoardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final DataService _dataService = ApiDataService();

  bool _isLoading = false;
  List<Dog> _dogs = [];
  final List<int> _selectedDogIds = [];

  DateTimeRange? _selectedDateRange;
  final TextEditingController _instructionsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadDogs();
  }

  Future<void> _loadDogs() async {
    try {
      final dogs = await _dataService.getDogs();
      if (mounted) {
        setState(() {
          _dogs = dogs;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load dogs: $e')),
        );
      }
    }
  }

  Future<void> _selectDateRange() async {
    final now = DateTime.now();
    final firstDate = now;
    final lastDate = now.add(const Duration(days: 365));

    final picked = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: lastDate,
      initialDateRange: _selectedDateRange,
    );

    if (picked != null) {
      setState(() {
        _selectedDateRange = picked;
      });
    }
  }

  Future<void> _submitRequest() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDogIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one dog')),
      );
      return;
    }
    if (_selectedDateRange == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select dates')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _dataService.createBoardingRequest(
        dogIds: _selectedDogIds,
        startDate: _selectedDateRange!.start,
        endDate: _selectedDateRange!.end,
        specialInstructions: _instructionsController.text.trim().isEmpty
            ? null
            : _instructionsController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Boarding request submitted successfully!')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Request Boarding'),
      ),
      body: _dogs.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Select Dogs',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  ..._dogs.map((dog) {
                    final isSelected = _selectedDogIds.contains(int.parse(dog.id));
                    return CheckboxListTile(
                      title: Text(dog.name),
                      value: isSelected,
                      onChanged: (bool? value) {
                        setState(() {
                          if (value == true) {
                            _selectedDogIds.add(int.parse(dog.id));
                          } else {
                            _selectedDogIds.remove(int.parse(dog.id));
                          }
                        });
                      },
                      secondary: dog.profileImageUrl != null
                          ? CircleAvatar(backgroundImage: NetworkImage(dog.profileImageUrl!))
                          : const CircleAvatar(child: Icon(Icons.pets)),
                    );
                  }).toList(),
                  const SizedBox(height: 24),
                  const Text(
                    'Select Dates',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: _selectDateRange,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.date_range),
                        labelText: 'Boarding Dates',
                      ),
                      child: Text(
                        _selectedDateRange != null
                            ? '${_selectedDateRange!.start.toString().split(' ')[0]} - ${_selectedDateRange!.end.toString().split(' ')[0]}'
                            : 'Select Date Range',
                        style: TextStyle(
                            color: _selectedDateRange != null
                                ? Colors.black
                                : Colors.grey[600]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Special Instructions',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _instructionsController,
                    decoration: const InputDecoration(
                      hintText: 'Any special care instructions, feeding, meds, etc.',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 4,
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _submitRequest,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Submit Request'),
                  ),
                ],
              ),
            ),
    );
  }
}
