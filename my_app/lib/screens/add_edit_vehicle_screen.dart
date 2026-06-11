import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';
import '../models/vehicle.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';

class AddEditVehicleScreen extends StatefulWidget {
  /// When null this screen creates a new vehicle; otherwise it edits [vehicle].
  final Vehicle? vehicle;

  const AddEditVehicleScreen({super.key, this.vehicle});

  @override
  State<AddEditVehicleScreen> createState() => _AddEditVehicleScreenState();
}

class _AddEditVehicleScreenState extends State<AddEditVehicleScreen> {
  final _formKey = GlobalKey<FormState>();
  final DataService _dataService = ApiDataService();
  final ImagePicker _picker = ImagePicker();

  late final TextEditingController _nameController;
  late final TextEditingController _registrationController;
  late final TextEditingController _makeController;
  late final TextEditingController _modelController;
  late final TextEditingController _notesController;

  String _status = 'ACTIVE';
  DateTime? _motDueDate;
  DateTime? _serviceDueDate;
  Uint8List? _imageBytes;
  String? _imageName;
  bool _isSaving = false;

  bool get _isEditing => widget.vehicle != null;

  @override
  void initState() {
    super.initState();
    final vehicle = widget.vehicle;
    _nameController = TextEditingController(text: vehicle?.name ?? '');
    _registrationController = TextEditingController(text: vehicle?.registration ?? '');
    _makeController = TextEditingController(text: vehicle?.make ?? '');
    _modelController = TextEditingController(text: vehicle?.model ?? '');
    _notesController = TextEditingController(text: vehicle?.notes ?? '');
    _status = vehicle?.status ?? 'ACTIVE';
    _motDueDate = vehicle?.motDueDate;
    _serviceDueDate = vehicle?.serviceDueDate;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _registrationController.dispose();
    _makeController.dispose();
    _modelController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (image != null) {
        final bytes = await image.readAsBytes();
        setState(() {
          _imageBytes = bytes;
          _imageName = image.name;
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

  Future<void> _pickDate(bool isMot) async {
    final current = isMot ? _motDueDate : _serviceDueDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (picked != null) {
      setState(() {
        if (isMot) {
          _motDueDate = picked;
        } else {
          _serviceDueDate = picked;
        }
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      final name = _nameController.text.trim();
      final registration = _registrationController.text.trim();
      final make = _makeController.text.trim();
      final model = _modelController.text.trim();
      final notes = _notesController.text.trim();
      if (_isEditing) {
        await _dataService.updateVehicle(
          widget.vehicle!.id,
          name: name,
          registration: registration,
          make: make,
          model: model,
          notes: notes,
          status: _status,
          motDueDate: _motDueDate,
          serviceDueDate: _serviceDueDate,
          imageBytes: _imageBytes,
          imageName: _imageName,
        );
      } else {
        await _dataService.createVehicle(
          name: name,
          registration: registration,
          make: make.isEmpty ? null : make,
          model: model.isEmpty ? null : model,
          notes: notes.isEmpty ? null : notes,
          status: _status,
          motDueDate: _motDueDate,
          serviceDueDate: _serviceDueDate,
          imageBytes: _imageBytes,
          imageName: _imageName,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEditing ? 'Vehicle updated' : 'Vehicle added'),
            backgroundColor: AppColors.success,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save vehicle: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Vehicle' : 'Add Vehicle'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(child: _buildImagePicker()),
            const SizedBox(height: 24),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Blue Van',
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _registrationController,
              decoration: const InputDecoration(
                labelText: 'Registration',
                hintText: 'e.g. AB12 CDE',
              ),
              textCapitalization: TextCapitalization.characters,
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _makeController,
                    decoration: const InputDecoration(
                      labelText: 'Make',
                      hintText: 'e.g. Ford',
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _modelController,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      hintText: 'e.g. Transit',
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Status'),
              value: _status,
              items: const [
                DropdownMenuItem(value: 'ACTIVE', child: Text('Active')),
                DropdownMenuItem(value: 'IN_SERVICE', child: Text('In Service/Garage')),
                DropdownMenuItem(value: 'OFF_ROAD', child: Text('Off Road')),
              ],
              onChanged: (value) => setState(() => _status = value ?? 'ACTIVE'),
            ),
            const SizedBox(height: 16),
            _buildDateRow('MOT due date', _motDueDate, () => _pickDate(true)),
            const SizedBox(height: 8),
            _buildDateRow('Service due date', _serviceDueDate, () => _pickDate(false)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                hintText: 'Anything useful to know about this vehicle',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(_isEditing ? 'Save Changes' : 'Add Vehicle'),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePicker() {
    final existingUrl = widget.vehicle?.imageUrl;
    Widget child;
    if (_imageBytes != null) {
      child = Image.memory(_imageBytes!, fit: BoxFit.cover);
    } else if (existingUrl != null) {
      child = CachedNetworkImage(imageUrl: existingUrl, fit: BoxFit.cover);
    } else {
      child = Container(
        color: Colors.grey[200],
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Picon(PiconsDuotone.cameraPlus, size: 40, color: Colors.grey[500]),
            const SizedBox(height: 8),
            Text('Add photo', style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: _showImageSourceDialog,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(width: 200, height: 140, child: child),
      ),
    );
  }

  Widget _buildDateRow(String label, DateTime? date, VoidCallback onTap) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Picon(PiconsDuotone.calendar),
      title: Text(label),
      subtitle: Text(date != null ? ukDate(date) : 'Not set'),
      trailing: TextButton(onPressed: onTap, child: const Text('Set date')),
      onTap: onTap,
    );
  }
}
