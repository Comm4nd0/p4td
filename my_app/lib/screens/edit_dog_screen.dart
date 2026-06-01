import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../constants/app_colors.dart';

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

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.dog.name);
    _foodController = TextEditingController(text: widget.dog.foodInstructions ?? '');
    _medicalController = TextEditingController(text: widget.dog.medicalNotes ?? '');
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

  Future<void> _checkUserRole() async {
    try {
      final profile = await _dataService.getProfile();
      if (profile.isStaff && mounted) {
        setState(() {
          _isStaff = true;
        });
      }
    } catch (e) {
      debugPrint('Error checking user role: $e');
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
          const SizedBox(height: 24),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
              prefixIcon: Picon(PiconsDuotone.pawPrint),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Care Instructions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _foodController,
            decoration: const InputDecoration(
              labelText: 'Food Instructions',
              hintText: 'e.g. 1 cup dry food twice a day',
              border: OutlineInputBorder(),
              prefixIcon: Picon(PiconsDuotone.forkKnife),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _medicalController,
            decoration: const InputDecoration(
              labelText: 'Medical / Injuries',
              hintText: 'e.g. recovering from surgery, allergic to chicken',
              border: OutlineInputBorder(),
              prefixIcon: Picon(PiconsDuotone.firstAid),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 24),
          const Text('About', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButtonFormField<DogSex?>(
            value: _selectedSex,
            decoration: const InputDecoration(
              labelText: 'Sex',
              border: OutlineInputBorder(),
              prefixIcon: Picon(PiconsDuotone.dog),
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
                labelText: 'Date of birth',
                border: const OutlineInputBorder(),
                prefixIcon: const Picon(PiconsDuotone.cake),
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
          SwitchListTile(
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
            _TransportDefaultRow(
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
            _TransportDefaultRow(
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
                'Daycare Schedule',
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
        ],
      ),
    );
  }
}

class _TransportDefaultRow extends StatelessWidget {
  final String label;
  final bool ownerSelected;
  final TimeOfDay? time;
  final TimeOfDay initialTimeIfUnset;
  final ValueChanged<bool> onOwnerChanged;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final VoidCallback onTimeCleared;

  const _TransportDefaultRow({
    required this.label,
    required this.ownerSelected,
    required this.time,
    required this.initialTimeIfUnset,
    required this.onOwnerChanged,
    required this.onTimeChanged,
    required this.onTimeCleared,
  });

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Staff'), icon: Picon(PiconsDuotone.van, size: 18)),
            ButtonSegment(value: true, label: Text('Owner'), icon: Picon(PiconsDuotone.houseLine, size: 18)),
          ],
          selected: {ownerSelected},
          onSelectionChanged: (s) => onOwnerChanged(s.first),
        ),
        if (ownerSelected) ...[
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(
              icon: const Picon(PiconsDuotone.clock, size: 18),
              label: Text(time == null ? 'Set time (optional)' : _fmt(time!)),
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: time ?? initialTimeIfUnset,
                );
                if (picked != null) onTimeChanged(picked);
              },
            ),
            if (time != null) ...[
              const SizedBox(width: 8),
              TextButton(onPressed: onTimeCleared, child: const Text('Clear')),
            ],
          ]),
        ],
      ],
    );
  }
}
