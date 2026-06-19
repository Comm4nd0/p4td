import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:image_picker/image_picker.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../models/dog.dart';
import '../models/owner_profile.dart';
import '../constants/app_colors.dart';
import '../widgets/postcode_lookup_dialog.dart';
import '../widgets/transport_default_row.dart';

class AddDogScreen extends StatefulWidget {
  const AddDogScreen({super.key});

  @override
  State<AddDogScreen> createState() => _AddDogScreenState();
}

class _AddDogScreenState extends State<AddDogScreen> {
  final _formKey = GlobalKey<FormState>();
  final DataService _dataService = getIt<DataService>();
  final ImagePicker _picker = ImagePicker();

  bool _isSaving = false;
  XFile? _selectedImage;
  Uint8List? _imageBytes;
  final Set<Weekday> _selectedDays = {};
  DropoffTime? _selectedDropoffTime;
  ScheduleType _selectedScheduleType = ScheduleType.weekly;
  bool _ownerBringsDefault = false;
  bool _ownerCollectsDefault = false;
  TimeOfDay? _ownerBringsDefaultTime;
  TimeOfDay? _ownerCollectsDefaultTime;

  bool _isStaff = false;
  List<OwnerProfile> _owners = [];
  String? _selectedOwnerId;
  bool _isLoadingOwners = false;

  DogSex? _selectedSex;
  DateTime? _selectedDateOfBirth;
  bool _isSpayed = false;
  bool _postcodeLookupEnabled = false;

  final _nameController = TextEditingController();
  final _foodController = TextEditingController();
  final _medicalController = TextEditingController();
  final _vetController = TextEditingController();
  final _addressController = TextEditingController();
  final _postcodeController = TextEditingController();
  final _accessController = TextEditingController();
  final _vanPlacementController = TextEditingController();
  final _generalNotesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkUserRole();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _foodController.dispose();
    _medicalController.dispose();
    _vetController.dispose();
    _addressController.dispose();
    _postcodeController.dispose();
    _accessController.dispose();
    _vanPlacementController.dispose();
    _generalNotesController.dispose();
    super.dispose();
  }

  Future<void> _checkUserRole() async {
    try {
      final profile = await _dataService.getProfile();
      if (mounted) setState(() => _postcodeLookupEnabled = profile.postcodeLookupEnabled);
      if (profile.isStaff) {
        setState(() {
          _isStaff = true;
          _isLoadingOwners = true;
        });
        await _fetchOwners();
      }
    } catch (e) {
      debugPrint('Error checking user role: $e');
    }
  }

  Future<void> _lookUpVetPostcode() async {
    final address = await showPostcodeLookup(context, _dataService);
    if (address == null || !mounted) return;
    final existing = _vetController.text.trimRight();
    setState(() {
      _vetController.text = existing.isEmpty ? address : '$existing\n$address';
    });
  }

  Future<void> _lookUpHomeAddressPostcode() async {
    final address = await showPostcodeLookup(context, _dataService);
    if (address == null || !mounted) return;
    setState(() {
      _addressController.text = address;
    });
  }

  Future<void> _fetchOwners() async {
    try {
      final owners = await _dataService.getOwners();
      setState(() {
        _owners = owners;
        _isLoadingOwners = false;
      });
    } catch (e) {
      debugPrint('Error fetching owners: $e');
      setState(() {
        _isLoadingOwners = false;
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (image != null) {
        final bytes = await image.readAsBytes();
        setState(() {
          _selectedImage = image;
          _imageBytes = bytes;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick image: $e')),
        );
      }
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Picon(PiconsDuotone.camera),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Picon(PiconsDuotone.images),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveDog() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
    });

    try {
      await _dataService.createDog(
        name: _nameController.text.trim(),
        foodInstructions: _foodController.text.trim().isEmpty ? null : _foodController.text.trim(),
        medicalNotes: _medicalController.text.trim().isEmpty ? null : _medicalController.text.trim(),
        registeredVet: _vetController.text.trim().isEmpty ? null : _vetController.text.trim(),
        address: _addressController.text.trim().isEmpty ? null : _addressController.text.trim(),
        postcode: _postcodeController.text.trim().isEmpty ? null : _postcodeController.text.trim().toUpperCase(),
        accessInstructions: _isStaff && _accessController.text.trim().isNotEmpty ? _accessController.text.trim() : null,
        vanPlacement: _isStaff && _vanPlacementController.text.trim().isNotEmpty ? _vanPlacementController.text.trim() : null,
        generalNotes: _isStaff && _generalNotesController.text.trim().isNotEmpty ? _generalNotesController.text.trim() : null,
        imageBytes: _imageBytes,
        imageName: _selectedImage?.name,
        daysInDaycare: _selectedDays.toList(),
        ownerId: _selectedOwnerId,
        preferredDropoffTime: _selectedDropoffTime,
        scheduleType: _selectedScheduleType,
        ownerBringsDefault: _isStaff ? _ownerBringsDefault : null,
        ownerCollectsDefault: _isStaff ? _ownerCollectsDefault : null,
        ownerBringsDefaultTime: _isStaff ? _ownerBringsDefaultTime : null,
        ownerCollectsDefaultTime: _isStaff ? _ownerCollectsDefaultTime : null,
        sex: _selectedSex,
        dateOfBirth: _selectedDateOfBirth,
        isSpayed: _isSpayed,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dog added successfully!')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add dog: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Dog'),
        actions: [
          IconButton(
            icon: Picon(PiconsDuotone.floppyDisk),
            onPressed: _isSaving ? null : _saveDog,
          ),
        ],
      ),
      body: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Photo Section
                      Center(
                        child: GestureDetector(
                          onTap: _showImageSourceDialog,
                          child: Container(
                            width: 150,
                            height: 150,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(75),
                              border: Border.all(color: Colors.grey[400]!, width: 2),
                            ),
                            child: _imageBytes != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(75),
                                    child: Image.memory(
                                      _imageBytes!,
                                      fit: BoxFit.cover,
                                      width: 150,
                                      height: 150,
                                    ),
                                  )
                                : Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Picon(PiconsDuotone.cameraPlus, size: 40, color: Colors.grey[600]),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Add Photo',
                                        style: TextStyle(color: Colors.grey[600]),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                      if (_imageBytes != null)
                        TextButton(
                          onPressed: () => setState(() {
                            _selectedImage = null;
                            _imageBytes = null;
                          }),
                          child: const Text('Remove Photo'),
                        ),
                      const SizedBox(height: 24),
                      if (_isStaff) ...[
                        if (_isLoadingOwners)
                          const Center(child: CircularProgressIndicator())
                        else
                          DropdownButtonFormField<String>(
                            decoration: const InputDecoration(
                              labelText: 'Assign Owner',                              prefixIcon: Picon(PiconsDuotone.userFocus),
                            ),
                            value: _selectedOwnerId,
                            items: _owners.map((owner) {
                              return DropdownMenuItem(
                                value: owner.userId.toString(),
                                child: Text('${owner.username} (${owner.email})'),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedOwnerId = value;
                              });
                            },
                            validator: (value) => value == null ? 'Required for staff' : null,
                          ),
                        const SizedBox(height: 24),
                      ],
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Dog Name',                          prefixIcon: Picon(PiconsDuotone.pawPrint),
                        ),
                        textCapitalization: TextCapitalization.words,
                        validator: (v) => v?.isEmpty ?? true ? 'Required' : null,
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Care Instructions (Optional)',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _foodController,
                        decoration: const InputDecoration(
                          labelText: 'Food Instructions',
                          hintText: 'e.g., 1 cup dry food twice a day',                          prefixIcon: Picon(PiconsDuotone.forkKnife),
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _medicalController,
                        decoration: const InputDecoration(
                          labelText: 'Medical Notes / Injuries',
                          hintText: 'e.g., recovering from surgery, allergies',                          prefixIcon: Picon(PiconsDuotone.firstAid),
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _vetController,
                        decoration: const InputDecoration(
                          labelText: 'Registered Vet (Optional)',
                          hintText: 'Practice name, address and phone number',                          prefixIcon: Picon(PiconsDuotone.stethoscope),
                        ),
                        textCapitalization: TextCapitalization.words,
                        maxLines: 3,
                      ),
                      if (_postcodeLookupEnabled)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _lookUpVetPostcode,
                            icon: const Picon(PiconsDuotone.mapPin, size: 18),
                            label: const Text('Look up postcode'),
                          ),
                        ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _addressController,
                        decoration: const InputDecoration(
                          labelText: 'Address (Optional)',
                          hintText: 'Home address for pickups and drop-offs',                          prefixIcon: Picon(PiconsDuotone.mapPin),
                        ),
                        textCapitalization: TextCapitalization.words,
                        maxLines: 3,
                      ),
                      if (_postcodeLookupEnabled)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _lookUpHomeAddressPostcode,
                            icon: const Picon(PiconsDuotone.mapPin, size: 18),
                            label: const Text('Look up postcode'),
                          ),
                        ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _postcodeController,
                        decoration: const InputDecoration(
                          labelText: 'Postcode (Optional)',
                          hintText: 'e.g. SL7 2HE — places the dog on the pickup map',
                          prefixIcon: Picon(PiconsDuotone.mapPin),
                        ),
                        textCapitalization: TextCapitalization.characters,
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'About',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<DogSex?>(
                        value: _selectedSex,
                        decoration: const InputDecoration(
                          labelText: 'Sex',                          prefixIcon: Picon(PiconsDuotone.dog),
                        ),
                        items: const [
                          DropdownMenuItem(value: null, child: Text('Unknown')),
                          DropdownMenuItem(value: DogSex.male, child: Text('Male')),
                          DropdownMenuItem(value: DogSex.female, child: Text('Female')),
                        ],
                        onChanged: (value) => setState(() => _selectedSex = value),
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDateOfBirth ?? DateTime(now.year - 2, now.month, now.day),
                            firstDate: DateTime(now.year - 30),
                            lastDate: now,
                          );
                          if (picked != null) {
                            setState(() => _selectedDateOfBirth = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Date of birth',                            prefixIcon: const Picon(PiconsDuotone.cake),
                            suffixIcon: _selectedDateOfBirth == null
                                ? null
                                : IconButton(
                                    icon: const Picon(PiconsDuotone.x),
                                    onPressed: () => setState(() => _selectedDateOfBirth = null),
                                  ),
                          ),
                          child: Text(
                            _selectedDateOfBirth == null
                                ? 'Not set'
                                : '${_selectedDateOfBirth!.day.toString().padLeft(2, '0')}/${_selectedDateOfBirth!.month.toString().padLeft(2, '0')}/${_selectedDateOfBirth!.year}',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Spayed / Neutered'),
                        secondary: const Picon(PiconsDuotone.heart),
                        value: _isSpayed,
                        onChanged: (v) => setState(() => _isSpayed = v),
                      ),
                      if (_isStaff) ...[
                        const SizedBox(height: 24),
                        const Text(
                          'Staff Notes',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Only visible to staff.',
                          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _accessController,
                          decoration: const InputDecoration(
                            labelText: 'Home Access',
                            hintText: 'Keys, codes, gates, where the dog is kept',
                            prefixIcon: Picon(PiconsDuotone.key),
                          ),
                          maxLines: 4,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _vanPlacementController,
                          decoration: const InputDecoration(
                            labelText: 'Van Placement',
                            hintText: 'Where the dog sits in the van, who with',
                            prefixIcon: Picon(PiconsDuotone.van),
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _generalNotesController,
                          decoration: const InputDecoration(
                            labelText: 'Notes',
                            hintText: 'General behaviour and handling notes',
                            prefixIcon: Picon(PiconsDuotone.notePencil),
                          ),
                          maxLines: 4,
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Transport defaults',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Who usually handles drop-off and pick-up for this dog? Staff-only; per-day exceptions can be set on each assignment.',
                          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                        ),
                        const SizedBox(height: 12),
                        TransportDefaultRow(
                          label: 'Drop-off (morning)',
                          ownerSelected: _ownerBringsDefault,
                          time: _ownerBringsDefaultTime,
                          initialTimeIfUnset: const TimeOfDay(hour: 8, minute: 0),
                          onOwnerChanged: (value) => setState(() {
                            _ownerBringsDefault = value;
                            if (!value) _ownerBringsDefaultTime = null;
                          }),
                          onTimeChanged: (t) => setState(() => _ownerBringsDefaultTime = t),
                          onTimeCleared: () => setState(() => _ownerBringsDefaultTime = null),
                        ),
                        const SizedBox(height: 12),
                        TransportDefaultRow(
                          label: 'Pick-up (evening)',
                          ownerSelected: _ownerCollectsDefault,
                          time: _ownerCollectsDefaultTime,
                          initialTimeIfUnset: const TimeOfDay(hour: 17, minute: 0),
                          onOwnerChanged: (value) => setState(() {
                            _ownerCollectsDefault = value;
                            if (!value) _ownerCollectsDefaultTime = null;
                          }),
                          onTimeChanged: (t) => setState(() => _ownerCollectsDefaultTime = t),
                          onTimeCleared: () => setState(() => _ownerCollectsDefaultTime = null),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Pickup & Drop-off',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.primaryLight.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: [
                              Picon(PiconsDuotone.clock, color: AppColors.primary, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'All dogs aim to be picked up from 08:00 to 09:30',
                                  style: TextStyle(color: AppColors.primary, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Preferred drop-off time:',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: DropoffTime.values.map((time) {
                            final isSelected = _selectedDropoffTime == time;
                            return ChoiceChip(
                              label: Text(time.displayName),
                              selected: isSelected,
                              onSelected: (selected) {
                                setState(() {
                                  _selectedDropoffTime = selected ? time : null;
                                });
                              },
                              avatar: isSelected
                                  ? Picon(PiconsFill.checkCircle, size: 18)
                                  : null,
                              backgroundColor: Colors.grey[200],
                              selectedColor: AppColors.primaryLight.withOpacity(0.2),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Schedule Frequency',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'How often does this dog attend?',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: ScheduleType.values.map((type) {
                            final isSelected = _selectedScheduleType == type;
                            return ChoiceChip(
                              label: Text(type.displayName),
                              selected: isSelected,
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() {
                                    _selectedScheduleType = type;
                                    if (type == ScheduleType.adHoc) {
                                      _selectedDays.clear();
                                    }
                                  });
                                }
                              },
                              avatar: isSelected
                                  ? Picon(PiconsFill.checkCircle, size: 18)
                                  : null,
                              backgroundColor: Colors.grey[200],
                              selectedColor: AppColors.primaryLight.withOpacity(0.2),
                            );
                          }).toList(),
                        ),
                        if (_selectedScheduleType == ScheduleType.adHoc) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.orange.withOpacity(0.4)),
                            ),
                            child: Row(
                              children: [
                                Picon(PiconsDuotone.info, color: Colors.orange[700], size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Ad hoc dogs can be assigned to any day by staff.',
                                    style: TextStyle(color: Colors.orange[700], fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (_selectedScheduleType != ScheduleType.adHoc) ...[
                          const SizedBox(height: 24),
                          const Text(
                            'Daycare Schedule (Optional)',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Select which days your dog attends daycare:',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: Weekday.values.map((day) {
                              final isSelected = _selectedDays.contains(day);
                              return FilterChip(
                                label: Text(day.displayName),
                                selected: isSelected,
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      _selectedDays.add(day);
                                    } else {
                                      _selectedDays.remove(day);
                                    }
                                  });
                                },
                                avatar: isSelected
                                    ? Picon(PiconsFill.checkCircle, size: 18)
                                    : null,
                                backgroundColor: Colors.grey[200],
                                selectedColor: AppColors.primaryLight.withOpacity(0.2),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                      const SizedBox(height: 32),
                      ElevatedButton.icon(
                        onPressed: _isSaving ? null : _saveDog,
                        icon: _isSaving 
                            ? const SizedBox(
                                width: 20, 
                                height: 20, 
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Picon(PiconsDuotone.plus),
                        label: Text(_isSaving ? 'Adding...' : 'Add Dog'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
