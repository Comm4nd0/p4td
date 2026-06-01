import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../utils/date_formats.dart';
import '../models/dog.dart';
import '../models/dog_note.dart';
import '../services/data_service.dart';
import '../widgets/skeleton_loaders.dart';

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

  Future<void> _editNote(DogNote note) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _EditDogNoteDialog(note: note),
    );
    if (result == null) return;

    try {
      await _dataService.updateDogNote(
        note.id,
        text: result['text'] as String?,
        isPositive: result['is_positive'] as bool?,
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update note: $e')),
        );
      }
    }
  }

  String? _otherDogNameForCurrent(DogNote note) {
    if (note.dogId != widget.dogId) return note.dogName;
    return note.relatedDogName;
  }

  PiconDuotoneData _iconForType(DogNoteType type) {
    switch (type) {
      case DogNoteType.compatibility:
        return PiconsDuotone.users;
      case DogNoteType.behavioral:
        return PiconsDuotone.brain;
      case DogNoteType.grouping:
        return PiconsDuotone.usersThree;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.dogName} - Notes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNote,
        icon: Picon(PiconsDuotone.plus),
        label: const Text('Add Note'),
      ),
      body: _loading
          ? const ListTileSkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: _notes.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Picon(PiconsDuotone.notePencil, size: 64, color: Colors.grey[400]),
                                const SizedBox(height: 16),
                                Text('No notes yet', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
                                const SizedBox(height: 8),
                                Text(
                                  'Add compatibility, behavioral, or grouping notes',
                                  style: TextStyle(color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
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
                                  Picon(
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
                                  Picon(
                                    note.isPositive ? PiconsDuotone.thumbsUp : PiconsDuotone.thumbsDown,
                                    size: 16,
                                    color: note.isPositive ? AppColors.success : AppColors.error,
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    icon: Picon(PiconsDuotone.pencilSimple, size: 20),
                                    onPressed: () => _editNote(note),
                                    color: AppColors.primary,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    tooltip: 'Edit',
                                  ),
                                  const SizedBox(width: 12),
                                  IconButton(
                                    icon: Picon(PiconsDuotone.trash, size: 20),
                                    onPressed: () => _deleteNote(note),
                                    color: AppColors.error,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    tooltip: 'Delete',
                                  ),
                                ],
                              ),
                              if (_otherDogNameForCurrent(note) != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Picon(PiconsDuotone.pawPrint, size: 16, color: AppColors.grey600),
                                    const SizedBox(width: 4),
                                    Text(
                                      'With ${_otherDogNameForCurrent(note)}',
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
                                '${note.createdByName ?? 'Unknown'} - ${ukDate(note.createdAt)}',
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
      widget.allDogs.where((d) => d.id != widget.dogId.toString()).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
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
              segments: [
                ButtonSegment(value: true, label: const Text('Positive'), icon: Picon(PiconsDuotone.thumbsUp, size: 16)),
                ButtonSegment(value: false, label: const Text('Negative'), icon: Picon(PiconsDuotone.thumbsDown, size: 16)),
              ],
              selected: {_isPositive},
              onSelectionChanged: (set) => setState(() => _isPositive = set.first),
            ),
            if (_noteType == DogNoteType.compatibility && _otherDogs.isNotEmpty) ...[
              const SizedBox(height: 16),
              _RelatedDogTypeahead(
                otherDogs: _otherDogs,
                selected: _relatedDog,
                onSelected: (dog) => setState(() => _relatedDog = dog),
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

class _RelatedDogTypeahead extends StatefulWidget {
  final List<Dog> otherDogs;
  final Dog? selected;
  final ValueChanged<Dog?> onSelected;

  const _RelatedDogTypeahead({
    required this.otherDogs,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<_RelatedDogTypeahead> createState() => _RelatedDogTypeaheadState();
}

class _RelatedDogTypeaheadState extends State<_RelatedDogTypeahead> {
  @override
  Widget build(BuildContext context) {
    return Autocomplete<Dog>(
      initialValue: TextEditingValue(text: widget.selected?.name ?? ''),
      displayStringForOption: (Dog d) => d.name,
      optionsBuilder: (TextEditingValue value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return widget.otherDogs;
        return widget.otherDogs.where((d) => d.name.toLowerCase().contains(query));
      },
      onSelected: widget.onSelected,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Related Dog (optional)',
            hintText: 'Search by name',
            prefixIcon: Picon(PiconsDuotone.magnifyingGlass, size: 20),
            border: const OutlineInputBorder(),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: Picon(PiconsDuotone.x, size: 18),
                    onPressed: () {
                      controller.clear();
                      widget.onSelected(null);
                    },
                  ),
          ),
          onChanged: (value) {
            if (widget.selected != null && value != widget.selected!.name) {
              widget.onSelected(null);
            }
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final dog = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: dog.profileImageUrl != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: CachedNetworkImage(
                              imageUrl: dog.profileImageUrl!,
                              width: 36,
                              height: 36,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                width: 36,
                                height: 36,
                                color: AppColors.grey200,
                              ),
                              errorWidget: (_, __, ___) => CircleAvatar(
                                radius: 18,
                                child: Picon(PiconsDuotone.pawPrint, size: 18),
                              ),
                            ),
                          )
                        : CircleAvatar(
                            radius: 18,
                            child: Picon(PiconsDuotone.pawPrint, size: 18),
                          ),
                    title: Text(dog.name),
                    subtitle: dog.ownerDetails != null
                        ? Text(
                            dog.ownerDetails!.username,
                            style: const TextStyle(fontSize: 12),
                          )
                        : null,
                    onTap: () => onSelected(dog),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EditDogNoteDialog extends StatefulWidget {
  final DogNote note;

  const _EditDogNoteDialog({required this.note});

  @override
  State<_EditDogNoteDialog> createState() => _EditDogNoteDialogState();
}

class _EditDogNoteDialogState extends State<_EditDogNoteDialog> {
  late bool _isPositive;
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _isPositive = widget.note.isPositive;
    _textController = TextEditingController(text: widget.note.text);
    _textController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasChanges = _textController.text.trim() != widget.note.text.trim()
        || _isPositive != widget.note.isPositive;
    final textValid = _textController.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Edit Note'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sentiment', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: const Text('Positive'), icon: Picon(PiconsDuotone.thumbsUp, size: 16)),
                ButtonSegment(value: false, label: const Text('Negative'), icon: Picon(PiconsDuotone.thumbsDown, size: 16)),
              ],
              selected: {_isPositive},
              onSelectionChanged: (set) => setState(() => _isPositive = set.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Note',
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
          onPressed: (!hasChanges || !textValid)
              ? null
              : () {
                  final result = <String, dynamic>{};
                  final newText = _textController.text.trim();
                  if (newText != widget.note.text.trim()) result['text'] = newText;
                  if (_isPositive != widget.note.isPositive) result['is_positive'] = _isPositive;
                  Navigator.pop(context, result);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
