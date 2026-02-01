import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/dog.dart';
import '../services/data_service.dart';

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
  late TextEditingController _breedController;
  late TextEditingController _foodController;
  late TextEditingController _medicalController;

  // Photo state
  String? _currentImageUrl;
  Uint8List? _newImageBytes;
  String? _newImageName;
  bool _deletePhoto = false;
  Set<Weekday> _selectedDays = {};

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.dog.name);
    _breedController = TextEditingController(text: widget.dog.breed);
    _foodController = TextEditingController(text: widget.dog.foodInstructions ?? '');
    _medicalController = TextEditingController(text: widget.dog.medicalNotes ?? '');
    _currentImageUrl = widget.dog.profileImageUrl;
    _selectedDays = Set.from(widget.dog.daysInDaycare);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
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
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            if (_currentImageUrl != null || _newImageBytes != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
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
      await _dataService.updateDog(
        widget.dog,
        name: _nameController.text,
        foodInstructions: _foodController.text,
        medicalNotes: _medicalController.text,
        imageBytes: _newImageBytes,
        imageName: _newImageName,
        deletePhoto: _deletePhoto,
        daysInDaycare: _selectedDays.toList(),
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dog updated successfully')),
        );
        Navigator.pop(context, true);
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
          Icon(Icons.add_a_photo, size: 40, color: Colors.grey[600]),
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
        child: Image.network(
          _currentImageUrl!,
          fit: BoxFit.cover,
          width: 150,
          height: 150,
          errorBuilder: (_, __, ___) => Icon(Icons.error, size: 40, color: Colors.grey[600]),
        ),
      );
    } else {
      // No photo
      imageWidget = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_a_photo, size: 40, color: Colors.grey[600]),
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
            icon: const Icon(Icons.save),
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
              prefixIcon: Icon(Icons.pets),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _breedController,
            decoration: const InputDecoration(
              labelText: 'Breed',
              border: OutlineInputBorder(),
              helperText: 'Cannot edit breed directly',
            ),
            enabled: false, 
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
              prefixIcon: Icon(Icons.restaurant),
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
              prefixIcon: Icon(Icons.medical_services),
            ),
            maxLines: 3,
          ),
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
                    ? const Icon(Icons.check_circle, size: 18)
                    : null,
                backgroundColor: Colors.grey[200],
                selectedColor: Colors.blue[100],
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
