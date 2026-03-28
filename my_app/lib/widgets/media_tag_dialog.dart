import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../services/data_service.dart';

/// Result returned from the media tagging dialog.
class MediaTagResult {
  final String? caption;
  final List<List<String>> taggedDogIdsByFile;

  MediaTagResult({this.caption, required this.taggedDogIdsByFile});
}

/// A dialog that presents each media item one at a time, letting the user
/// tag which dogs are in each item, plus an optional shared caption.
class MediaTagDialog extends StatefulWidget {
  /// List of (bytes, filename, isVideo) for each media item.
  final List<(Uint8List, String, bool)> files;

  const MediaTagDialog({super.key, required this.files});

  @override
  State<MediaTagDialog> createState() => _MediaTagDialogState();
}

class _MediaTagDialogState extends State<MediaTagDialog> {
  final DataService _dataService = ApiDataService();
  final TextEditingController _captionController = TextEditingController();
  final PageController _pageController = PageController();

  List<Dog> _allDogs = [];
  bool _loadingDogs = true;
  int _currentPage = 0;

  /// One set of selected dog IDs per file.
  late List<Set<String>> _selectedDogsByFile;

  @override
  void initState() {
    super.initState();
    _selectedDogsByFile = List.generate(widget.files.length, (_) => <String>{});
    _loadDogs();
  }

  @override
  void dispose() {
    _captionController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadDogs() async {
    try {
      final dogs = await _dataService.getDogs();
      dogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) setState(() { _allDogs = dogs; _loadingDogs = false; });
    } catch (e) {
      if (mounted) setState(() => _loadingDogs = false);
    }
  }

  void _goToNext() {
    if (_currentPage < widget.files.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPrevious() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _submit() {
    final tagsByFile = _selectedDogsByFile
        .map((set) => set.toList())
        .toList();
    Navigator.pop(
      context,
      MediaTagResult(
        caption: _captionController.text.trim().isEmpty
            ? null
            : _captionController.text.trim(),
        taggedDogIdsByFile: tagsByFile,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMultiple = widget.files.length > 1;
    final isLastPage = _currentPage == widget.files.length - 1;

    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(isMultiple
              ? 'Tag Dogs (${_currentPage + 1}/${widget.files.length})'
              : 'Tag Dogs'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            if (!isMultiple || isLastPage)
              TextButton(
                onPressed: _submit,
                child: const Text('Upload', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        body: Column(
          children: [
            // Media preview & dog selection (paged)
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (page) => setState(() => _currentPage = page),
                itemCount: widget.files.length,
                itemBuilder: (context, index) {
                  final (bytes, fileName, isVideo) = widget.files[index];
                  return _buildFileTagPage(bytes, fileName, isVideo, index);
                },
              ),
            ),
            // Caption field (shared across all files)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _captionController,
                decoration: const InputDecoration(
                  hintText: 'Write a caption (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
              ),
            ),
            // Navigation buttons for multiple files
            if (isMultiple)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    if (_currentPage > 0)
                      OutlinedButton.icon(
                        onPressed: _goToPrevious,
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('Previous'),
                      )
                    else
                      const SizedBox.shrink(),
                    const Spacer(),
                    if (!isLastPage)
                      FilledButton.icon(
                        onPressed: _goToNext,
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        label: const Text('Next'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _submit,
                        icon: PhosphorIcon(PhosphorIconsDuotone.uploadSimple, size: 18),
                        label: const Text('Upload All'),
                      ),
                  ],
                ),
              )
            else
              const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildFileTagPage(Uint8List bytes, String fileName, bool isVideo, int fileIndex) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Media preview
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: isVideo
                ? Container(
                    width: double.infinity,
                    height: 200,
                    color: Colors.black,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PhosphorIcon(PhosphorIconsDuotone.videoCamera, color: Colors.white, size: 48),
                          const SizedBox(height: 8),
                          Text(
                            fileName,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  )
                : Image.memory(
                    bytes,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(height: 16),
          // Dog selection
          const Text(
            'Which dogs are in this?',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          if (_loadingDogs)
            const Center(child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ))
          else if (_allDogs.isEmpty)
            Text('No dogs found', style: TextStyle(color: Colors.grey[500]))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _allDogs.map((dog) {
                final isSelected = _selectedDogsByFile[fileIndex].contains(dog.id);
                return FilterChip(
                  avatar: dog.profileImageUrl != null
                      ? CircleAvatar(
                          backgroundImage: CachedNetworkImageProvider(dog.profileImageUrl!),
                        )
                      : CircleAvatar(
                          backgroundColor: AppColors.primaryLight.withAlpha(40),
                          child: Text(
                            dog.name.isNotEmpty ? dog.name[0].toUpperCase() : '?',
                            style: const TextStyle(fontSize: 12, color: AppColors.primary),
                          ),
                        ),
                  label: Text(dog.name),
                  selected: isSelected,
                  onSelected: (val) {
                    setState(() {
                      if (val) {
                        _selectedDogsByFile[fileIndex].add(dog.id);
                      } else {
                        _selectedDogsByFile[fileIndex].remove(dog.id);
                      }
                    });
                  },
                  selectedColor: AppColors.primaryLight.withAlpha(40),
                  checkmarkColor: AppColors.primary,
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}
