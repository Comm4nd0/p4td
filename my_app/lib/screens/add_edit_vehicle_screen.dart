import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';
import '../models/vehicle.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/page_body.dart';
import 'dashboard/reassign_dogs_dialog.dart' show staffDisplayName;

class AddEditVehicleScreen extends StatefulWidget {
  /// When null this screen creates a new vehicle; otherwise it edits [vehicle].
  final Vehicle? vehicle;

  const AddEditVehicleScreen({super.key, this.vehicle});

  @override
  State<AddEditVehicleScreen> createState() => _AddEditVehicleScreenState();
}

class _AddEditVehicleScreenState extends State<AddEditVehicleScreen> {
  final _formKey = GlobalKey<FormState>();
  final DataService _dataService = getIt<DataService>();
  final ImagePicker _picker = ImagePicker();

  late final TextEditingController _nameController;
  late final TextEditingController _registrationController;
  late final TextEditingController _makeController;
  late final TextEditingController _modelController;
  late final TextEditingController _notesController;
  late final TextEditingController _capacityController;

  String _status = 'ACTIVE';
  DateTime? _motDueDate;
  DateTime? _serviceDueDate;
  DateTime? _taxDueDate;
  Uint8List? _imageBytes;
  String? _imageName;
  bool _isSaving = false;
  int? _usualDriverId;
  List<Map<String, dynamic>> _staffMembers = const [];

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
    _taxDueDate = vehicle?.taxDueDate;
    _capacityController = TextEditingController(text: vehicle?.dogCapacity?.toString() ?? '');
    _usualDriverId = vehicle?.usualDriverId;
    _loadStaff();
  }

  Future<void> _loadStaff() async {
    try {
      final staff = await _dataService.getStaffMembers();
      if (mounted) setState(() => _staffMembers = staff);
    } catch (_) {
      // The picker just stays empty; the rest of the form still saves.
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _registrationController.dispose();
    _makeController.dispose();
    _modelController.dispose();
    _notesController.dispose();
    _capacityController.dispose();
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

  Future<void> _pickDate(String field) async {
    final current = switch (field) {
      'mot' => _motDueDate,
      'service' => _serviceDueDate,
      _ => _taxDueDate,
    };
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (picked != null) {
      setState(() {
        if (field == 'mot') {
          _motDueDate = picked;
        } else if (field == 'service') {
          _serviceDueDate = picked;
        } else {
          _taxDueDate = picked;
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
      final capacity = int.tryParse(_capacityController.text.trim());
      final int vehicleId;
      if (_isEditing) {
        vehicleId = widget.vehicle!.id;
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
          taxDueDate: _taxDueDate,
          imageBytes: _imageBytes,
          imageName: _imageName,
        );
      } else {
        final created = await _dataService.createVehicle(
          name: name,
          registration: registration,
          make: make.isEmpty ? null : make,
          model: model.isEmpty ? null : model,
          notes: notes.isEmpty ? null : notes,
          status: _status,
          motDueDate: _motDueDate,
          serviceDueDate: _serviceDueDate,
          taxDueDate: _taxDueDate,
          imageBytes: _imageBytes,
          imageName: _imageName,
        );
        vehicleId = created.id;
      }
      final routingChanged = capacity != widget.vehicle?.dogCapacity ||
          _usualDriverId != widget.vehicle?.usualDriverId;
      if (routingChanged) {
        await _dataService.updateVehicleRouting(vehicleId, dogCapacity: capacity, usualDriverId: _usualDriverId);
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
      body: PageBody(child: Form(
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
            _buildDateRow('MOT due date', _motDueDate, () => _pickDate('mot')),
            const SizedBox(height: 8),
            _buildDateRow('Service due date', _serviceDueDate, () => _pickDate('service')),
            const SizedBox(height: 8),
            _buildDateRow('Tax due date', _taxDueDate, () => _pickDate('tax')),
            const SizedBox(height: 16),
            ..._buildRouteFields(),
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
      )),
    );
  }

  /// Dog capacity and usual driver — what Plan Routes reads to know each
  /// driver's van.
  List<Widget> _buildRouteFields() {
    final staffIds = _staffMembers.map((s) => s['id']).toSet();
    return [
      Text('Route planning', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      TextFormField(
        controller: _capacityController,
        decoration: const InputDecoration(
          labelText: 'Dogs it can carry (optional)',
          hintText: 'Leave blank if unsure',
        ),
        keyboardType: TextInputType.number,
        validator: (v) {
          final text = v?.trim() ?? '';
          if (text.isEmpty) return null;
          final n = int.tryParse(text);
          return n == null || n < 1 ? 'Enter a whole number, or leave blank' : null;
        },
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<int?>(
        decoration: const InputDecoration(labelText: 'Usual driver (optional)'),
        // The list arrives after the form opens; until it does, show nobody
        // rather than an id the dropdown has no item for.
        value: staffIds.contains(_usualDriverId) ? _usualDriverId : null,
        items: [
          const DropdownMenuItem<int?>(value: null, child: Text('Nobody')),
          for (final s in _staffMembers)
            DropdownMenuItem<int?>(value: s['id'] as int, child: Text(staffDisplayName(s))),
        ],
        onChanged: _staffMembers.isEmpty ? null : (value) => setState(() => _usualDriverId = value),
      ),
    ];
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
