import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../models/boarding_request.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';

/// Create a new boarding request, or — when [existing] is passed — edit the
/// dates and instructions of an existing booking. In edit mode the dogs are
/// fixed (shown read-only): to board different dogs, make a new request.
class RequestBoardingScreen extends StatefulWidget {
  final BoardingRequest? existing;

  const RequestBoardingScreen({super.key, this.existing});

  @override
  State<RequestBoardingScreen> createState() => _RequestBoardingScreenState();
}

class _RequestBoardingScreenState extends State<RequestBoardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final DataService _dataService = getIt<DataService>();

  bool _isLoading = false;
  bool _isLoadingDogs = true;
  List<Dog> _dogs = [];
  final List<int> _selectedDogIds = [];

  DateTimeRange? _selectedDateRange;
  final TextEditingController _instructionsController = TextEditingController();

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      // Dogs aren't editable, so no need to load the pickable dog list.
      _isLoadingDogs = false;
      _selectedDateRange = DateTimeRange(
        start: widget.existing!.startDate,
        end: widget.existing!.endDate,
      );
      _instructionsController.text = widget.existing!.specialInstructions ?? '';
    } else {
      _loadDogs();
    }
  }

  @override
  void dispose() {
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _loadDogs() async {
    try {
      final dogs = await _dataService.getDogs();
      if (mounted) {
        setState(() {
          _dogs = dogs;
          _isLoadingDogs = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingDogs = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load dogs: $e')),
        );
      }
    }
  }

  Future<void> _selectDateRange() async {
    final now = DateTime.now();
    // When editing a booking that already started, allow keeping its original
    // (past) start date rather than forcing it forward.
    var firstDate = DateTime(now.year, now.month, now.day);
    if (_selectedDateRange != null && _selectedDateRange!.start.isBefore(firstDate)) {
      firstDate = _selectedDateRange!.start;
    }
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
    if (!_isEditing && _selectedDogIds.isEmpty) {
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
      if (_isEditing) {
        await _dataService.updateBoardingRequest(
          widget.existing!.id,
          startDate: _selectedDateRange!.start,
          endDate: _selectedDateRange!.end,
          specialInstructions: _instructionsController.text.trim(),
        );
      } else {
        await _dataService.createBoardingRequest(
          dogIds: _selectedDogIds,
          startDate: _selectedDateRange!.start,
          endDate: _selectedDateRange!.end,
          specialInstructions: _instructionsController.text.trim().isEmpty
              ? null
              : _instructionsController.text.trim(),
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isEditing
              ? 'Boarding booking updated'
              : 'Boarding request submitted successfully!')),
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
        title: Text(_isEditing ? 'Edit Boarding' : 'Request Boarding'),
      ),
      body: _isLoadingDogs
          ? const Center(child: CircularProgressIndicator())
          : (!_isEditing && _dogs.isEmpty)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Picon(PiconsDuotone.pawPrint, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          'No dogs on your account',
                          style: TextStyle(
                              fontSize: 18,
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Please contact staff to have your dog added to your profile before requesting boarding.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_isEditing) ...[
                    const Text(
                      'Dogs',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(child: Picon(PiconsDuotone.pawPrint)),
                      title: Text(widget.existing!.dogNames.join(', ')),
                      subtitle: const Text('Dogs can\'t be changed here — make a new request to board different dogs.'),
                    ),
                  ] else ...[
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
                            : CircleAvatar(child: Picon(PiconsDuotone.pawPrint)),
                      );
                    }).toList(),
                  ],
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
                        prefixIcon: Picon(PiconsDuotone.calendarDots),
                        labelText: 'Boarding Dates',
                      ),
                      child: Text(
                        _selectedDateRange != null
                            ? '${ukDate(_selectedDateRange!.start)} - ${ukDate(_selectedDateRange!.end)}'
                            : 'Select Date Range',
                        style: TextStyle(
                            color: _selectedDateRange != null
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context).colorScheme.onSurfaceVariant),
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
                        : Text(_isEditing ? 'Save Changes' : 'Submit Request'),
                  ),
                ],
              ),
            ),
    );
  }
}
