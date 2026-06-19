import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../constants/app_colors.dart';
import '../widgets/postcode_lookup_dialog.dart';
import '../widgets/transport_default_row.dart';

class EditDogScreen extends StatefulWidget {
  final Dog dog;

  const EditDogScreen({super.key, required this.dog});

  @override
  State<EditDogScreen> createState() => _EditDogScreenState();
}

class _EditDogScreenState extends State<EditDogScreen> {
  final DataService _dataService = ApiDataService();
  final ImagePicker _picker = ImagePicker();
  bool _isSaving = false;

  late TextEditingController _nameController;
  late TextEditingController _foodController;
  late TextEditingController _medicalController;
  late TextEditingController _vetController;
  late TextEditingController _addressController;
  late TextEditingController _postcodeController;
  late TextEditingController _accessController;
  late TextEditingController _vanPlacementController;
  late TextEditingController _generalNotesController;

  // Photo state
  String? _currentImageUrl;
  Uint8List? _newImageBytes;
  String? _newImageName;
  bool _deletePhoto = false;
  Set<Weekday> _selectedDays = {};
  DropoffTime? _selectedDropoffTime;
  ScheduleType _selectedScheduleType = ScheduleType.weekly;
  bool _isStaff = false;
  bool _ownerBringsDefault = false;
  bool _ownerCollectsDefault = false;
  TimeOfDay? _ownerBringsDefaultTime;
  TimeOfDay? _ownerCollectsDefaultTime;
  DogSex? _selectedSex;
  DateTime? _selectedDateOfBirth;
  bool _isSpayed = false;
  bool _postcodeLookupEnabled = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.dog.name);
    _foodController = TextEditingController(text: widget.dog.foodInstructions ?? '');
    _medicalController = TextEditingController(text: widget.dog.medicalNotes ?? '');
    _vetController = TextEditingController(text: widget.dog.registeredVet ?? '');
    _addressController = TextEditingController(text: widget.dog.address ?? '');
    _postcodeController = TextEditingController(text: widget.dog.postcode ?? '');
    _accessController = TextEditingController(text: widget.dog.accessInstructions ?? '');
    _vanPlacementController = TextEditingController(text: widget.dog.vanPlacement ?? '');
    _generalNotesController = TextEditingController(text: widget.dog.generalNotes ?? '');
    _currentImageUrl = widget.dog.profileImageUrl;
    _selectedDays = Set.from(widget.dog.daysInDaycare);
    _selectedDropoffTime = widget.dog.preferredDropoffTime;
    _selectedScheduleType = widget.dog.scheduleType;
    _ownerBringsDefault = widget.dog.ownerBringsDefault;
    _ownerCollectsDefault = widget.dog.ownerCollectsDefault;
    _ownerBringsDefaultTime = widget.dog.ownerBringsDefaultTime;
    _ownerCollectsDefaultTime = widget.dog.ownerCollectsDefaultTime;
    _selectedSex = widget.dog.sex;
    _selectedDateOfBirth = widget.dog.dateOfBirth;
    _isSpayed = widget.dog.isSpayed;
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
      if (!mounted) return;
      setState(() {
        _isStaff = profile.isStaff;
        _postcodeLookupEnabled = profile.postcodeLookupEnabled;
      });
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
          _newImageBytes = bytes;
          _newImageName = image.name;
          _deletePhoto = false;
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
            if (_currentImageUrl != null || _newImageBytes != null)
              ListTile(
                leading: Picon(PiconsDuotone.trash, color: Colors.red),
                title: const Text('Remove Photo', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _newImageBytes = null;
                    _newImageName = null;
                    _deletePhoto = true;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveDog() async {
    setState(() {
      _isSaving = true;
    });

    try {
      final updatedDog = await _dataService.updateDog(
        widget.dog,
        name: _nameController.text,
        foodInstructions: _foodController.text,
        medicalNotes: _medicalController.text,
        registeredVet: _vetController.text,
        address: _addressController.text,
        postcode: _postcodeController.text.trim().toUpperCase(),
        accessInstructions: _isStaff ? _accessController.text : null,
        vanPlacement: _isStaff ? _vanPlacementController.text : null,
        generalNotes: _isStaff ? _generalNotesController.text : null,
        imageBytes: _newImageBytes,
        imageName: _newImageName,
        deletePhoto: _deletePhoto,
        daysInDaycare: _selectedDays.toList(),
        preferredDropoffTime: _selectedDropoffTime,
        scheduleType: _selectedScheduleType,
        ownerBringsDefault: _isStaff ? _ownerBringsDefault : null,
        ownerCollectsDefault: _isStaff ? _ownerCollectsDefault : null,
        ownerBringsDefaultTime: _isStaff ? _ownerBringsDefaultTime : null,
        ownerCollectsDefaultTime: _isStaff ? _ownerCollectsDefaultTime : null,
        sex: _selectedSex,
        dateOfBirth: _selectedDateOfBirth,
        clearDateOfBirth: _selectedDateOfBirth == null && widget.dog.dateOfBirth != null,
        isSpayed: _isStaff ? _isSpayed : null,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dog updated successfully')),
        );
        Navigator.pop(context, updatedDog);
      }
    } on DogUpdatePendingApprovalException {
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            icon: Icon(Icons.hourglass_top_rounded, color: Colors.orange[700], size: 48),
            title: const Text('Changes Pending Approval'),
            content: const Text(
              'Your changes have been sent to the staff team for review. '
              'You\'ll receive a notification once they\'ve been approved.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
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

  Widget _buildPhotoSection() {
    Widget imageWidget;
    
    if (_deletePhoto) {
      // Photo will be deleted
      imageWidget = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Picon(PiconsDuotone.cameraPlus, size: 40, color: Colors.grey[600]),
          const SizedBox(height: 8),
          Text('Add Photo', style: TextStyle(color: Colors.grey[600])),
        ],
      );
    } else if (_newImageBytes != null) {
      // New photo selected
      imageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(75),
        child: Image.memory(
          _newImageBytes!,
          fit: BoxFit.cover,
          width: 150,
          height: 150,
        ),
      );
    } else if (_currentImageUrl != null) {
      // Existing photo
      imageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(75),
        child: CachedNetworkImage(
          imageUrl: _currentImageUrl!,
          fit: BoxFit.cover,
          width: 150,
          height: 150,
          placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
          errorWidget: (_, __, ___) => Picon(PiconsDuotone.warningCircle, size: 40, color: Colors.grey[600]),
        ),
      );
    } else {
      // No photo
      imageWidget = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Picon(PiconsDuotone.cameraPlus, size: 40, color: Colors.grey[600]),
          const SizedBox(height: 8),
          Text('Add Photo', style: TextStyle(color: Colors.grey[600])),
        ],
      );
    }

    return Center(
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
          child: imageWidget,
        ),
      ),
    );
  }

  /// Small pill showing whether a field/section is visible to the dog's owner
  /// in their app, or hidden (staff-only).
  Widget _visibilityBadge({required bool visibleToOwner}) {
    final color = visibleToOwner ? AppColors.success : AppColors.grey600;
    final icon = visibleToOwner ? PiconsDuotone.eye : PiconsDuotone.eyeSlash;
    final label = visibleToOwner ? 'Visible to owner' : 'Hidden from owner';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Picon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  /// Section header with an optional owner-visibility badge. The badge is only
  /// shown to staff — owners only ever see their own (visible) fields, so the
  /// distinction is meaningless to them.
  Widget _sectionHeader(String title, {double fontSize = 18, bool? visibleToOwner}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold),
          ),
        ),
        if (_isStaff && visibleToOwner != null) ...[
          const SizedBox(width: 8),
          _visibilityBadge(visibleToOwner: visibleToOwner),
        ],
      ],
    );
  }

  /// Explains the visibility badges. Staff-only.
  Widget _buildVisibilityLegend() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primaryLight.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Picon(PiconsDuotone.eye, color: AppColors.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Badges show what the owner sees in their app. '
              'Fields marked “Hidden from owner” are staff-only.',
              style: TextStyle(color: AppColors.primary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit ${widget.dog.name}'),
        actions: [
          IconButton(
            icon: Picon(PiconsDuotone.floppyDisk),
            onPressed: _isSaving ? null : _saveDog,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPhotoSection(),
          if (_isStaff) ...[
            const SizedBox(height: 20),
            _buildVisibilityLegend(),
          ],
          const SizedBox(height: 24),
          _sectionHeader('Basics', visibleToOwner: true),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name',              prefixIcon: Picon(PiconsDuotone.pawPrint),
            ),
          ),
          const SizedBox(height: 16),
          _sectionHeader('Care Instructions', visibleToOwner: true),
          const SizedBox(height: 8),
          TextField(
            controller: _foodController,
            decoration: const InputDecoration(
              labelText: 'Food Instructions',
              hintText: 'e.g. 1 cup dry food twice a day',              prefixIcon: Picon(PiconsDuotone.forkKnife),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _medicalController,
            decoration: const InputDecoration(
              labelText: 'Medical / Injuries',
              hintText: 'e.g. recovering from surgery, allergic to chicken',              prefixIcon: Picon(PiconsDuotone.firstAid),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _vetController,
            decoration: const InputDecoration(
              labelText: 'Registered Vet',
              hintText: 'Practice name, address and phone number',              prefixIcon: Picon(PiconsDuotone.stethoscope),
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
          TextField(
            controller: _addressController,
            decoration: const InputDecoration(
              labelText: 'Address',
              hintText: 'Home address for pickups and drop-offs',              prefixIcon: Picon(PiconsDuotone.mapPin),
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
          TextField(
            controller: _postcodeController,
            decoration: const InputDecoration(
              labelText: 'Postcode',
              hintText: 'e.g. SL7 2HE — used to place the dog on the pickup map',
              prefixIcon: Picon(PiconsDuotone.mapPin),
            ),
            textCapitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 24),
          _sectionHeader('About', visibleToOwner: true),
          const SizedBox(height: 8),
          DropdownButtonFormField<DogSex?>(
            value: _selectedSex,
            decoration: const InputDecoration(
              labelText: 'Sex',              prefixIcon: Picon(PiconsDuotone.dog),
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
                labelText: 'Date of birth',                prefixIcon: const Picon(PiconsDuotone.cake),
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
            subtitle: Text(
              _isStaff
                  ? 'Only staff can change this.'
                  : 'View only — ask a staff member to update.',
              style: const TextStyle(fontSize: 12),
            ),
            secondary: const Picon(PiconsDuotone.heart),
            value: _isSpayed,
            onChanged: _isStaff ? (v) => setState(() => _isSpayed = v) : null,
          ),
          if (_isStaff) ...[
            const SizedBox(height: 24),
            _sectionHeader('Staff Notes', fontSize: 16, visibleToOwner: false),
            const SizedBox(height: 4),
            Text(
              'Access details, van placement and handling notes. The owner never sees these.',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _accessController,
              decoration: const InputDecoration(
                labelText: 'Home Access',
                hintText: 'Keys, codes, gates, where the dog is kept',
                prefixIcon: Picon(PiconsDuotone.key),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _vanPlacementController,
              decoration: const InputDecoration(
                labelText: 'Van Placement',
                hintText: 'Where the dog sits in the van, who with',
                prefixIcon: Picon(PiconsDuotone.van),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _generalNotesController,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'General behaviour and handling notes',
                prefixIcon: Picon(PiconsDuotone.notePencil),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 24),
            _sectionHeader('Transport defaults', fontSize: 16, visibleToOwner: false),
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
            _sectionHeader('Pickup & Drop-off', fontSize: 16, visibleToOwner: false),
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
            _sectionHeader('Schedule Frequency', fontSize: 16, visibleToOwner: true),
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
              _sectionHeader('Daycare Schedule', fontSize: 16, visibleToOwner: true),
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
        ],
      ),
    );
  }
}
