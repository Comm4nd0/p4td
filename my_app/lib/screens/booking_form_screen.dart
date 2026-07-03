import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/intake_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/postcode_lookup_dialog.dart';

/// Per-dog form state on the booking form. Controllers live for the lifetime
/// of the screen and are disposed with it.
class _DogEntry {
  final nameController = TextEditingController();
  final foodController = TextEditingController();
  final medicalController = TextEditingController();
  final vetController = TextEditingController();
  DogSex? sex;
  DateTime? dateOfBirth;
  bool isSpayed = false;
  ScheduleType scheduleType = ScheduleType.weekly;
  final Set<Weekday> days = {};

  void dispose() {
    nameController.dispose();
    foodController.dispose();
    medicalController.dispose();
    vetController.dispose();
  }

  IntakeDog toIntakeDog() {
    return IntakeDog(
      name: nameController.text.trim(),
      sex: sex,
      dateOfBirth: dateOfBirth,
      isSpayed: isSpayed,
      foodInstructions: foodController.text.trim(),
      medicalNotes: medicalController.text.trim(),
      registeredVet: vetController.text.trim(),
      daysInDaycare: days.toList()..sort((a, b) => a.index.compareTo(b.index)),
      scheduleType: scheduleType,
    );
  }
}

/// The booking form: the second step after creating an account. Captures the
/// owner's contact details and everything staff need to intake their dog(s).
/// Submitting creates a pending request that staff approve or deny.
class BookingFormScreen extends StatefulWidget {
  const BookingFormScreen({super.key});

  @override
  State<BookingFormScreen> createState() => _BookingFormScreenState();
}

class _BookingFormScreenState extends State<BookingFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final DataService _dataService = getIt<DataService>();

  bool _isSubmitting = false;
  bool _postcodeLookupEnabled = false;

  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _postcodeController = TextEditingController();
  final _pickupController = TextEditingController();
  final _additionalInfoController = TextEditingController();

  final List<_DogEntry> _dogs = [_DogEntry()];

  @override
  void initState() {
    super.initState();
    _prefillFromProfile();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _addressController.dispose();
    _postcodeController.dispose();
    _pickupController.dispose();
    _additionalInfoController.dispose();
    for (final dog in _dogs) {
      dog.dispose();
    }
    super.dispose();
  }

  Future<void> _prefillFromProfile() async {
    try {
      final profile = await _dataService.getProfile();
      if (!mounted) return;
      setState(() {
        _postcodeLookupEnabled = profile.postcodeLookupEnabled;
        if (_phoneController.text.isEmpty) {
          _phoneController.text = profile.phoneNumber ?? '';
        }
        if (_addressController.text.isEmpty) {
          _addressController.text = profile.address ?? '';
        }
        if (_pickupController.text.isEmpty) {
          _pickupController.text = profile.pickupInstructions ?? '';
        }
      });
    } catch (e) {
      debugPrint('Failed to prefill booking form: $e');
    }
  }

  Future<void> _lookUpHomePostcode() async {
    final address = await showPostcodeLookup(context, _dataService);
    if (address == null || !mounted) return;
    setState(() => _addressController.text = address);
  }

  Future<void> _lookUpVetPostcode(_DogEntry dog) async {
    final address = await showPostcodeLookup(context, _dataService);
    if (address == null || !mounted) return;
    final existing = dog.vetController.text.trimRight();
    setState(() {
      dog.vetController.text = existing.isEmpty ? address : '$existing\n$address';
    });
  }

  void _addDog() {
    setState(() => _dogs.add(_DogEntry()));
  }

  void _removeDog(int index) {
    setState(() {
      final removed = _dogs.removeAt(index);
      removed.dispose();
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);
    try {
      await _dataService.submitIntakeRequest(
        phoneNumber: _phoneController.text.trim(),
        address: _addressController.text.trim(),
        postcode: _postcodeController.text.trim().toUpperCase(),
        pickupInstructions: _pickupController.text.trim(),
        additionalInfo: _additionalInfoController.text.trim(),
        dogs: _dogs.map((d) => d.toIntakeDog()).toList(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Booking form submitted! Staff will review it shortly.'),
            backgroundColor: AppColors.success,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Booking Form')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primaryLight.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Picon(PiconsDuotone.info, color: AppColors.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tell us about you and your dog(s). Staff will review your '
                      'booking form and confirm your place.',
                      style: TextStyle(color: AppColors.primary, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Your Details',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phoneController,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                prefixIcon: Picon(PiconsDuotone.phone),
              ),
              keyboardType: TextInputType.phone,
              validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _addressController,
              decoration: const InputDecoration(
                labelText: 'Home Address',
                hintText: 'Where we pick up and drop off your dog(s)',
                prefixIcon: Picon(PiconsDuotone.house),
              ),
              textCapitalization: TextCapitalization.words,
              maxLines: 3,
              validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
            ),
            if (_postcodeLookupEnabled)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _lookUpHomePostcode,
                  icon: const Picon(PiconsDuotone.mapPin, size: 18),
                  label: const Text('Look up postcode'),
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _postcodeController,
              decoration: const InputDecoration(
                labelText: 'Postcode',
                hintText: 'e.g. SL7 2HE',
                prefixIcon: Picon(PiconsDuotone.mapPin),
              ),
              textCapitalization: TextCapitalization.characters,
              validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pickupController,
              decoration: const InputDecoration(
                labelText: 'Pickup Instructions (Optional)',
                hintText: 'Keys, gates, where the dog waits',
                prefixIcon: Picon(PiconsDuotone.key),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 24),
            const Text(
              'Your Dogs',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < _dogs.length; i++) _buildDogCard(i),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addDog,
                icon: const Picon(PiconsDuotone.plus, size: 18),
                label: const Text('Add another dog'),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Anything Else?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _additionalInfoController,
              decoration: const InputDecoration(
                labelText: 'Additional Information (Optional)',
                hintText: 'Anything else staff should know',
                prefixIcon: Picon(PiconsDuotone.notePencil),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _isSubmitting ? null : _submit,
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Picon(PiconsDuotone.paperPlaneTilt),
              label: Text(_isSubmitting ? 'Submitting...' : 'Submit Booking Form'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDogCard(int index) {
    final dog = _dogs[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Picon(PiconsDuotone.pawPrint, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Dog ${index + 1}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                if (_dogs.length > 1)
                  IconButton(
                    icon: const Picon(PiconsDuotone.trash, size: 20),
                    tooltip: 'Remove this dog',
                    onPressed: () => _removeDog(index),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: dog.nameController,
              decoration: const InputDecoration(
                labelText: 'Dog Name',
                prefixIcon: Picon(PiconsDuotone.pawPrint),
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<DogSex?>(
              value: dog.sex,
              decoration: const InputDecoration(
                labelText: 'Sex',
                prefixIcon: Picon(PiconsDuotone.dog),
              ),
              items: const [
                DropdownMenuItem(value: null, child: Text('Unknown')),
                DropdownMenuItem(value: DogSex.male, child: Text('Male')),
                DropdownMenuItem(value: DogSex.female, child: Text('Female')),
              ],
              onChanged: (value) => setState(() => dog.sex = value),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: dog.dateOfBirth ?? DateTime(now.year - 2, now.month, now.day),
                  firstDate: DateTime(now.year - 30),
                  lastDate: now,
                );
                if (picked != null) {
                  setState(() => dog.dateOfBirth = picked);
                }
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Date of birth',
                  prefixIcon: const Picon(PiconsDuotone.cake),
                  suffixIcon: dog.dateOfBirth == null
                      ? null
                      : IconButton(
                          icon: const Picon(PiconsDuotone.x),
                          onPressed: () => setState(() => dog.dateOfBirth = null),
                        ),
                ),
                child: Text(
                  dog.dateOfBirth == null
                      ? 'Not set'
                      : '${dog.dateOfBirth!.day.toString().padLeft(2, '0')}/${dog.dateOfBirth!.month.toString().padLeft(2, '0')}/${dog.dateOfBirth!.year}',
                ),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Spayed / Neutered'),
              secondary: const Picon(PiconsDuotone.heart),
              value: dog.isSpayed,
              onChanged: (v) => setState(() => dog.isSpayed = v),
            ),
            const SizedBox(height: 4),
            TextFormField(
              controller: dog.foodController,
              decoration: const InputDecoration(
                labelText: 'Food Instructions (Optional)',
                hintText: 'e.g., 1 cup dry food twice a day',
                prefixIcon: Picon(PiconsDuotone.forkKnife),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: dog.medicalController,
              decoration: const InputDecoration(
                labelText: 'Medical Notes / Allergies (Optional)',
                hintText: 'e.g., allergies, medication, injuries',
                prefixIcon: Picon(PiconsDuotone.firstAid),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: dog.vetController,
              decoration: const InputDecoration(
                labelText: 'Registered Vet (Optional)',
                hintText: 'Practice name, address and phone number',
                prefixIcon: Picon(PiconsDuotone.stethoscope),
              ),
              textCapitalization: TextCapitalization.words,
              maxLines: 3,
            ),
            if (_postcodeLookupEnabled)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _lookUpVetPostcode(dog),
                  icon: const Picon(PiconsDuotone.mapPin, size: 18),
                  label: const Text('Look up postcode'),
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'How often would they attend?',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: ScheduleType.values.map((type) {
                final isSelected = dog.scheduleType == type;
                return ChoiceChip(
                  label: Text(type.displayName),
                  selected: isSelected,
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        dog.scheduleType = type;
                        if (type == ScheduleType.adHoc) dog.days.clear();
                      });
                    }
                  },
                  avatar: isSelected ? Picon(PiconsFill.checkCircle, size: 18) : null,
                  backgroundColor: Colors.grey[200],
                  selectedColor: AppColors.primaryLight.withOpacity(0.2),
                );
              }).toList(),
            ),
            if (dog.scheduleType != ScheduleType.adHoc) ...[
              const SizedBox(height: 16),
              const Text(
                'Which days would they attend?',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: Weekday.values.map((day) {
                  final isSelected = dog.days.contains(day);
                  return FilterChip(
                    label: Text(day.displayName),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          dog.days.add(day);
                        } else {
                          dog.days.remove(day);
                        }
                      });
                    },
                    avatar: isSelected ? Picon(PiconsFill.checkCircle, size: 18) : null,
                    backgroundColor: Colors.grey[200],
                    selectedColor: AppColors.primaryLight.withOpacity(0.2),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
