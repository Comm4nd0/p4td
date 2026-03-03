import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/dog_note.dart';
import '../services/data_service.dart';

class DogNotesScreen extends StatefulWidget {
  final int dogId;
  final String dogName;

  const DogNotesScreen({super.key, required this.dogId, required this.dogName});

  @override
  State<DogNotesScreen> createState() => _DogNotesScreenState();
}

class _DogNotesScreenState extends State<DogNotesScreen> {
  final DataService _dataService = ApiDataService();
  List<DogNote> _notes = [];
  bool _loading = true;
  List<Dog> _allDogs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final notes = await _dataService.getDogNotes(dogId: widget.dogId);
      final dogs = await _dataService.getDogs();
      if (mounted) {
        setState(() {
          _notes = notes;
          _allDogs = dogs;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load notes: $e')),
        );
      }
    }
  }

  Future<void> _addNote() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _AddDogNoteDialog(
        dogId: widget.dogId,
        dogName: widget.dogName,
        allDogs: _allDogs,
      ),
    );
    if (result == null) return;

    try {
      await _dataService.createDogNote(
        dogId: widget.dogId,
        relatedDogId: result['related_dog_id'],
        noteType: result['note_type'],
        text: result['text'],
        isPositive: result['is_positive'],
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create note: $e')),
        );
      }
    }
  }

  Future<void> _deleteNote(DogNote note) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Are you sure you want to delete this note?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _dataService.deleteDogNote(note.id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete note: $e')),
        );
      }
    }
  }

  IconData _iconForType(DogNoteType type) {
    switch (type) {
      case DogNoteType.compatibility:
        return Icons.people;
      case DogNoteType.behavioral:
        return Icons.psychology;
      case DogNoteType.grouping:
        return Icons.groups;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.dogName} - Notes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNote,
        icon: const Icon(Icons.add),
        label: const Text('Add Note'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.note_add, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('No notes yet', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
                      const SizedBox(height: 8),
                      Text(
                        'Add compatibility, behavioral, or grouping notes',
                        style: TextStyle(color: Colors.grey[500]),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _notes.length,
                    itemBuilder: (context, index) {
                      final note = _notes[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _iconForType(note.noteType),
                                    size: 20,
                                    color: AppColors.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryLight.withAlpha(30),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      note.noteType.displayName,
                                      style: const TextStyle(fontSize: 12, color: AppColors.primary),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    note.isPositive ? Icons.thumb_up : Icons.thumb_down,
                                    size: 16,
                                    color: note.isPositive ? AppColors.success : AppColors.error,
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 20),
                                    onPressed: () => _deleteNote(note),
                                    color: AppColors.error,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                ],
                              ),
                              if (note.relatedDogName != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.pets, size: 16, color: AppColors.grey600),
                                    const SizedBox(width: 4),
                                    Text(
                                      'With ${note.relatedDogName}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.grey700,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 8),
                              Text(note.text, style: const TextStyle(fontSize: 15)),
                              const SizedBox(height: 8),
                              Text(
                                '${note.createdByName ?? 'Unknown'} - ${DateFormat('d MMM yyyy').format(note.createdAt)}',
                                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _AddDogNoteDialog extends StatefulWidget {
  final int dogId;
  final String dogName;
  final List<Dog> allDogs;

  const _AddDogNoteDialog({
    required this.dogId,
    required this.dogName,
    required this.allDogs,
  });

  @override
  State<_AddDogNoteDialog> createState() => _AddDogNoteDialogState();
}

class _AddDogNoteDialogState extends State<_AddDogNoteDialog> {
  DogNoteType _noteType = DogNoteType.compatibility;
  bool _isPositive = true;
  Dog? _relatedDog;
  final _textController = TextEditingController();

  List<Dog> get _otherDogs =>
      widget.allDogs.where((d) => d.id != widget.dogId.toString()).toList();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add Note for ${widget.dogName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Type', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SegmentedButton<DogNoteType>(
              segments: const [
                ButtonSegment(value: DogNoteType.compatibility, label: Text('Compat.')),
                ButtonSegment(value: DogNoteType.behavioral, label: Text('Behavior')),
                ButtonSegment(value: DogNoteType.grouping, label: Text('Group')),
              ],
              selected: {_noteType},
              onSelectionChanged: (set) => setState(() => _noteType = set.first),
            ),
            const SizedBox(height: 16),
            const Text('Sentiment', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Positive'), icon: Icon(Icons.thumb_up, size: 16)),
                ButtonSegment(value: false, label: Text('Negative'), icon: Icon(Icons.thumb_down, size: 16)),
              ],
              selected: {_isPositive},
              onSelectionChanged: (set) => setState(() => _isPositive = set.first),
            ),
            if (_noteType == DogNoteType.compatibility && _otherDogs.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<Dog>(
                value: _relatedDog,
                decoration: const InputDecoration(
                  labelText: 'Related Dog (optional)',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  ..._otherDogs.map((d) => DropdownMenuItem(value: d, child: Text(d.name))),
                ],
                onChanged: (dog) => setState(() => _relatedDog = dog),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Note',
                hintText: 'e.g. Gets along great with Buddy during playtime',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _textController.text.trim().isEmpty
              ? null
              : () {
                  Navigator.pop(context, {
                    'note_type': _noteType,
                    'text': _textController.text.trim(),
                    'is_positive': _isPositive,
                    'related_dog_id': _relatedDog != null ? int.tryParse(_relatedDog!.id) : null,
                  });
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
