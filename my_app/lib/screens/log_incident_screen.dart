import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/incident.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/dog_typeahead.dart';

/// Write-up form for a new incident.
///
/// Staff-only, like everything else in the incident log. The form asks for the
/// things that matter later — who was involved and how, what happened, what
/// was done about it, whether a vet is needed — and takes photos or video,
/// because a wound is easier to show than to describe.
class LogIncidentScreen extends StatefulWidget {
  /// Pre-selects a dog when the form is opened from that dog's profile.
  final String? initialDogId;
  final String? initialDogName;

  const LogIncidentScreen({super.key, this.initialDogId, this.initialDogName});

  @override
  State<LogIncidentScreen> createState() => _LogIncidentScreenState();
}

class _LogIncidentScreenState extends State<LogIncidentScreen> {
  final _formKey = GlobalKey<FormState>();
  final DataService _dataService = getIt<DataService>();
  final ImagePicker _picker = ImagePicker();

  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _injuriesController = TextEditingController();
  final _actionController = TextEditingController();
  final _vetDetailsController = TextEditingController();

  String _type = 'SCUFFLE';
  String _severity = 'LOW';
  bool _vetRequired = false;
  DateTime _occurredAt = DateTime.now();

  List<Dog> _allDogs = [];
  bool _loadingDogs = true;
  final Map<String, IncidentDogEntry> _selectedDogs = {};

  /// Photos and video, as (bytes, filename) — the filename is what tells the
  /// server which is which.
  final List<(Uint8List, String)> _media = [];
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadDogs();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    _injuriesController.dispose();
    _actionController.dispose();
    _vetDetailsController.dispose();
    super.dispose();
  }

  Future<void> _loadDogs() async {
    try {
      final dogs = await _dataService.getDogs();
      if (!mounted) return;
      setState(() {
        _allDogs = dogs;
        _loadingDogs = false;
        final initialId = widget.initialDogId;
        if (initialId != null) {
          final dog = dogs.where((d) => d.id == initialId).firstOrNull;
          _selectedDogs[initialId] = IncidentDogEntry(
            dogId: initialId,
            dogName: dog?.name ?? widget.initialDogName ?? 'Dog',
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingDogs = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load dogs: $e')),
      );
    }
  }

  void _onDogsChanged(Set<String> selected) {
    setState(() {
      _selectedDogs.removeWhere((id, _) => !selected.contains(id));
      for (final id in selected) {
        if (_selectedDogs.containsKey(id)) continue;
        final dog = _allDogs.where((d) => d.id == id).firstOrNull;
        _selectedDogs[id] = IncidentDogEntry(dogId: id, dogName: dog?.name ?? 'Dog');
      }
    });
  }

  Future<void> _pickWhen() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (!mounted) return;
    setState(() {
      _occurredAt = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? _occurredAt.hour,
        time?.minute ?? _occurredAt.minute,
      );
    });
  }

  Future<void> _addFromCamera({bool video = false}) async {
    try {
      final XFile? file = video
          ? await _picker.pickVideo(source: ImageSource.camera)
          : await _picker.pickImage(
              source: ImageSource.camera,
              maxWidth: 1600,
              maxHeight: 1600,
              imageQuality: 85,
            );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() => _media.add((bytes, file.name)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to capture: $e')));
    }
  }

  Future<void> _addFromGallery() async {
    try {
      // Same caps as the feed uploader: the native picker downscales images
      // (video passes through) so full-resolution originals never sit in
      // memory or crawl over a rural connection.
      final files = await _picker.pickMultipleMedia(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      for (final file in files) {
        _media.add((await file.readAsBytes(), file.name));
      }
      if (files.isNotEmpty && mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to pick media: $e')));
    }
  }

  void _showMediaSourceSheet() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Picon(PiconsDuotone.camera),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addFromCamera();
              },
            ),
            ListTile(
              leading: Picon(PiconsDuotone.videoCamera),
              title: const Text('Record Video'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addFromCamera(video: true);
              },
            ),
            ListTile(
              leading: Picon(PiconsDuotone.images),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDogs.isEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('No dogs named'),
          content: const Text(
              'Incidents are normally tied to the dogs involved so they show on '
              'their profiles. Log this one without any dogs?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Go back')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Log anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() => _isSaving = true);
    try {
      await _dataService.createIncident(
        title: _titleController.text.trim(),
        incidentType: _type,
        severity: _severity,
        occurredAt: _occurredAt,
        dogs: _selectedDogs.values.toList(),
        location: _locationController.text.trim(),
        description: _descriptionController.text.trim(),
        injuries: _injuriesController.text.trim(),
        actionTaken: _actionController.text.trim(),
        vetRequired: _vetRequired,
        vetDetails: _vetDetailsController.text.trim(),
        media: _media,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Incident logged'), backgroundColor: AppColors.success),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to log incident: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log Incident')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Picon(PiconsDuotone.lock, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Staff only — incidents are never shown to owners in the app.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'What happened?',
                hintText: 'e.g. Scuffle in the back paddock',
              ),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final (value, label) in kIncidentTypes)
                  DropdownMenuItem(value: value, child: Text(label)),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 16),
            const Text('Severity', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final (value, label) in kIncidentSeverities)
                  ChoiceChip(
                    label: Text(label),
                    selected: _severity == value,
                    selectedColor: incidentSeverityColor(value).withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: _severity == value ? incidentSeverityColor(value) : null,
                      fontWeight: _severity == value ? FontWeight.bold : null,
                    ),
                    onSelected: (_) => setState(() => _severity = value),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Picon(PiconsDuotone.clock, color: AppColors.primary),
              title: const Text('When'),
              subtitle: Text(ukDateTimeWithDay(_occurredAt)),
              trailing: TextButton(onPressed: _pickWhen, child: const Text('Change')),
            ),
            TextFormField(
              controller: _locationController,
              decoration: const InputDecoration(
                labelText: 'Where (optional)',
                hintText: 'e.g. Back paddock, in the van',
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 24),
            const Text('Dogs involved', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            if (_loadingDogs)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator.adaptive()),
              )
            else
              DogMultiSelectTypeahead(
                dogs: _allDogs,
                selectedDogIds: _selectedDogs.keys.toSet(),
                onChanged: _onDogsChanged,
                hintText: 'Search dogs involved...',
              ),
            const SizedBox(height: 8),
            for (final entry in _selectedDogs.values) _buildDogEntryCard(entry),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Account of what happened',
                hintText: 'What led up to it, what happened, who saw it…',
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 5,
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _injuriesController,
              decoration: const InputDecoration(
                labelText: 'Injuries (optional)',
                hintText: 'Any injuries overall — per-dog detail goes above',
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _actionController,
              decoration: const InputDecoration(
                labelText: 'Action taken (optional)',
                hintText: 'Separated, first aid given, owner rang…',
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _vetRequired,
              title: const Text('Vet involved / needed'),
              secondary: Picon(PiconsDuotone.stethoscope, color: AppColors.primary),
              onChanged: (v) => setState(() => _vetRequired = v),
            ),
            if (_vetRequired)
              TextFormField(
                controller: _vetDetailsController,
                decoration: const InputDecoration(
                  labelText: 'Vet details',
                  hintText: 'Practice, treatment, follow-up',
                ),
                textCapitalization: TextCapitalization.sentences,
                maxLines: 3,
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Text('Photos & video', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                TextButton.icon(
                  onPressed: _showMediaSourceSheet,
                  icon: Picon(PiconsDuotone.cameraPlus, size: 20),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (_media.isEmpty)
              Text('Nothing attached', style: TextStyle(color: Colors.grey[600]))
            else
              SizedBox(
                height: 100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _media.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _buildMediaThumb(index),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _isSaving ? null : _submit,
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Log Incident'),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildDogEntryCard(IncidentDogEntry entry) {
    return Card(
      // Keyed by dog so removing one from the list doesn't leave its typed
      // injuries sitting under the dog that takes its place.
      key: ValueKey(entry.dogId),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Picon(PiconsDuotone.pawPrint, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(entry.dogName,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                DropdownButton<String>(
                  value: entry.role,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final (value, label) in kIncidentRoles)
                      DropdownMenuItem(
                          value: value, child: Text(label, style: const TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) => setState(() => entry.role = v ?? entry.role),
                ),
              ],
            ),
            TextFormField(
              initialValue: entry.injuries,
              decoration: InputDecoration(
                isDense: true,
                labelText: 'Injuries to ${entry.dogName} (optional)',
              ),
              textCapitalization: TextCapitalization.sentences,
              onChanged: (v) => entry.injuries = v,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaThumb(int index) {
    final (bytes, name) = _media[index];
    final isVideo = _looksLikeVideo(name);
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: isVideo
              ? Container(
                  width: 100,
                  height: 100,
                  color: Colors.black87,
                  child: Center(
                    child: Picon(PiconsDuotone.play, color: Colors.white, size: 28),
                  ),
                )
              : Image.memory(bytes, width: 100, height: 100, fit: BoxFit.cover),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () => setState(() => _media.removeAt(index)),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 16, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  static bool _looksLikeVideo(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.mp4') ||
        n.endsWith('.mov') ||
        n.endsWith('.m4v') ||
        n.endsWith('.3gp') ||
        n.endsWith('.avi') ||
        n.endsWith('.webm');
  }
}
