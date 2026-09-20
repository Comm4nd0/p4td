import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/intake_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/postcode_lookup_dialog.dart';
import '../widgets/page_body.dart';
import '../widgets/vaccination_certificate_picker.dart';
import 'link_dog_screen.dart';

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

  /// The vet's certificate, required before the form can be submitted. The
  /// form itself is JSON, so the file is uploaded right after it, per dog;
  /// [serverId] and [certificateUploaded] let a failed upload be retried
  /// without submitting the form twice.
  PickedCertificate? certificate;
  DateTime? lastVaccinationDate;
  int? serverId;
  bool certificateUploaded = false;

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
      lastVaccinationDate: lastVaccinationDate,
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

  /// Set once the form itself is on the server; a retry after a failed
  /// certificate upload then only uploads what is still missing.
  int? _submittedRequestId;

  final _phoneController = TextEditingController();
  final _emergencyContactController = TextEditingController();
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
    _emergencyContactController.dispose();
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

  Future<void> _pickCertificate(_DogEntry dog) async {
    final picked = await pickVaccinationCertificate(context);
    if (picked == null || !mounted) return;
    setState(() {
      dog.certificate = picked;
      dog.certificateUploaded = false;
    });
  }

  Future<void> _pickVaccinationDate(_DogEntry dog) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: dog.lastVaccinationDate ?? now,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      helpText: 'Date of last vaccination',
    );
    if (picked != null && mounted) setState(() => dog.lastVaccinationDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);
    _DogEntry? uploading;
    try {
      if (_submittedRequestId == null) {
        final request = await _dataService.submitIntakeRequest(
          phoneNumber: _phoneController.text.trim(),
          emergencyContactNumber: _emergencyContactController.text.trim(),
          address: _addressController.text.trim(),
          postcode: _postcodeController.text.trim().toUpperCase(),
          pickupInstructions: _pickupController.text.trim(),
          additionalInfo: _additionalInfoController.text.trim(),
          dogs: _dogs.map((d) => d.toIntakeDog()).toList(),
        );
        _submittedRequestId = request.id;
        // The server keeps the dogs in the order they were sent.
        for (var i = 0; i < _dogs.length && i < request.dogs.length; i++) {
          _dogs[i].serverId = request.dogs[i].id;
        }
      }
      for (final dog in _dogs) {
        final picked = dog.certificate;
        if (dog.certificateUploaded || dog.serverId == null || picked == null) continue;
        uploading = dog;
        await _dataService.uploadIntakeCertificate(
          requestId: _submittedRequestId!,
          intakeDogId: dog.serverId!,
          bytes: picked.bytes,
          filename: picked.name,
          vaccinationDate: dog.lastVaccinationDate,
        );
        dog.certificateUploaded = true;
      }
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
        final message = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(uploading == null
                ? message
                : "Your form is in, but ${uploading.nameController.text.trim()}'s certificate "
                    "didn't upload: $message Tap Submit to try again."),
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// The required certificate, as a FormField so the form's validate() covers
  /// it and the error reads inline like every other required field.
  Widget _certificateField(_DogEntry dog) {
    return FormField<PickedCertificate>(
      validator: (_) => dog.certificate == null ? "Please attach your dog's vaccination certificate" : null,
      builder: (state) {
        final picked = dog.certificate;
        final date = dog.lastVaccinationDate;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Vaccination certificate',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(
              "A photo of the vet's card or the PDF. We need it on file for our licence "
              "records before your dog's first day.",
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Picon(
                picked == null ? PiconsDuotone.paperclip : PiconsDuotone.checkCircle,
                color: picked == null
                    ? (state.hasError ? AppColors.error : AppColors.primary)
                    : AppColors.success,
              ),
              title: Text(
                picked == null ? 'Attach certificate (required)' : picked.name,
                style: TextStyle(
                  color: picked == null ? AppColors.primary : null,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: picked == null
                  ? null
                  : Text('${(picked.bytes.length / 1024).round()} KB · tap to change'),
              trailing: picked == null
                  ? null
                  : IconButton(
                      icon: const Picon(PiconsDuotone.x),
                      tooltip: 'Remove',
                      onPressed: () => setState(() => dog.certificate = null),
                    ),
              onTap: () => _pickCertificate(dog),
            ),
            if (state.hasError)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  state.errorText!,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
                ),
              ),
            InkWell(
              onTap: () => _pickVaccinationDate(dog),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Date of last vaccination (optional)',
                  prefixIcon: const Picon(PiconsDuotone.syringe),
                  suffixIcon: date == null
                      ? null
                      : IconButton(
                          icon: const Picon(PiconsDuotone.x),
                          onPressed: () => setState(() => dog.lastVaccinationDate = null),
                        ),
                ),
                child: Text(
                  date == null
                      ? 'Not set'
                      : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}',
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Dog Booking Form')),
      body: PageBody(child: Form(
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Picon(PiconsDuotone.info, color: AppColors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "This form is for a dog that hasn't been to Paws 4 Thought "
                          'before. Tell us about you and your dog(s) and staff will '
                          'confirm your place.',
                          style: TextStyle(color: AppColors.primary, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // The wrong form here hands staff a duplicate dog, so the
                  // other door is right in the banner.
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const LinkDogScreen()),
                      ),
                      icon: const Picon(PiconsDuotone.link, size: 16),
                      label: const Text('Already come to daycare? Link my dog instead'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
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
              controller: _emergencyContactController,
              decoration: const InputDecoration(
                labelText: 'Emergency Contact Number',
                hintText: "If we can't reach you — e.g. 07700 900123 (Sue, neighbour)",
                prefixIcon: Picon(PiconsDuotone.firstAidKit),
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
                hintText: 'Keys, gates, where the dog waits — saved to each dog, editable later',
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
      )),
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
            _certificateField(dog),
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
