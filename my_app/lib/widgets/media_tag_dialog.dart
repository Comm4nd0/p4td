import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:video_player/video_player.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import 'dog_typeahead.dart';

/// Result returned from the media tagging dialog.
class MediaTagResult {
  final List<String?> captionsByFile;
  final List<List<String>> taggedDogIdsByFile;

  /// Possibly-cropped bytes for each file, in the same order as the files
  /// passed in. For videos (or images the user didn't crop) this is the
  /// original bytes.
  final List<Uint8List> bytesByFile;

  MediaTagResult({
    required this.captionsByFile,
    required this.taggedDogIdsByFile,
    required this.bytesByFile,
  });

  /// Convenience getter for single-file uploads.
  String? get caption => captionsByFile.isNotEmpty ? captionsByFile[0] : null;
}

/// A dialog that presents each media item one at a time, letting the user
/// tag which dogs are in each item, plus a caption per item.
class MediaTagDialog extends StatefulWidget {
  /// List of (bytes, filename, isVideo) for each media item.
  final List<(Uint8List, String, bool)> files;

  const MediaTagDialog({super.key, required this.files});

  @override
  State<MediaTagDialog> createState() => _MediaTagDialogState();
}

class _MediaTagDialogState extends State<MediaTagDialog> {
  final DataService _dataService = ApiDataService();
  final PageController _pageController = PageController();

  List<Dog> _allDogs = [];
  bool _loadingDogs = true;
  int _currentPage = 0;

  /// One caption controller per file.
  late List<TextEditingController> _captionControllers;

  /// One set of selected dog IDs per file.
  late List<Set<String>> _selectedDogsByFile;

  /// Mutable copy of each file's bytes — replaced when the user crops.
  late List<Uint8List> _bytesByFile;

  @override
  void initState() {
    super.initState();
    _captionControllers = List.generate(widget.files.length, (_) => TextEditingController());
    _selectedDogsByFile = List.generate(widget.files.length, (_) => <String>{});
    _bytesByFile = widget.files.map((f) => f.$1).toList();
    _loadDogs();
  }

  @override
  void dispose() {
    for (final c in _captionControllers) {
      c.dispose();
    }
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
    final captions = _captionControllers
        .map((c) => c.text.trim().isEmpty ? null : c.text.trim())
        .toList();
    Navigator.pop(
      context,
      MediaTagResult(
        captionsByFile: captions,
        taggedDogIdsByFile: tagsByFile,
        bytesByFile: List<Uint8List>.from(_bytesByFile),
      ),
    );
  }

  void _openEnlargedImage(Uint8List bytes) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _EnlargedImageView(bytes: bytes),
    ));
  }

  Future<void> _cropImage(int fileIndex) async {
    final (_, fileName, _) = widget.files[fileIndex];
    final bytes = _bytesByFile[fileIndex];

    // image_cropper needs a file path; write the current bytes to a temp file.
    File? tempInput;
    try {
      final dir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      tempInput = File('${dir.path}/p4td_crop_input_${timestamp}_$fileName');
      await tempInput.writeAsBytes(bytes);

      final theme = Theme.of(context);
      final cropped = await ImageCropper().cropImage(
        sourcePath: tempInput.path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 90,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop photo',
            toolbarColor: theme.colorScheme.primary,
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: theme.colorScheme.primary,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
            hideBottomControls: false,
          ),
          IOSUiSettings(
            title: 'Crop photo',
            aspectRatioLockEnabled: false,
            resetAspectRatioEnabled: true,
          ),
        ],
      );

      if (cropped == null) return; // User cancelled.

      final croppedFile = File(cropped.path);
      final newBytes = await croppedFile.readAsBytes();
      unawaited(croppedFile.delete().catchError((_) => croppedFile));
      if (!mounted) return;
      setState(() {
        _bytesByFile[fileIndex] = newBytes;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not crop image: $e'), backgroundColor: Colors.red),
      );
    } finally {
      final cleanup = tempInput;
      if (cleanup != null) {
        unawaited(cleanup.delete().catchError((_) => cleanup));
      }
    }
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
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            if (isMultiple && !isLastPage)
              TextButton(
                onPressed: _submit,
                child: const Text('Upload all', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            if (!isMultiple || isLastPage)
              TextButton(
                onPressed: _submit,
                child: const Text('Upload', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              // Media preview, dog selection & caption (paged)
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  itemCount: widget.files.length,
                  itemBuilder: (context, index) {
                    final (_, fileName, isVideo) = widget.files[index];
                    return _buildFileTagPage(_bytesByFile[index], fileName, isVideo, index);
                  },
                ),
              ),
              // Navigation buttons for multiple files
              if (isMultiple)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _submit,
                      icon: PhosphorIcon(PhosphorIconsDuotone.uploadSimple, size: 18),
                      label: const Text('Upload'),
                    ),
                  ),
                ),
            ],
          ),
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
                ? _LocalVideoPlayer(bytes: bytes, fileName: fileName)
                : GestureDetector(
                    onTap: () => _openEnlargedImage(bytes),
                    child: Container(
                      width: double.infinity,
                      height: 300,
                      color: Colors.black,
                      child: Stack(
                        children: [
                          InteractiveViewer(
                            minScale: 1.0,
                            maxScale: 5.0,
                            clipBehavior: Clip.hardEdge,
                            child: SizedBox.expand(
                              child: Image.memory(
                                bytes,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 8,
                            top: 8,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(Icons.zoom_in, color: Colors.white, size: 14),
                                    SizedBox(width: 4),
                                    Text(
                                      'Pinch to zoom',
                                      style: TextStyle(color: Colors.white, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 8,
                            bottom: 8,
                            child: Material(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () => _cropImage(fileIndex),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      PhosphorIcon(
                                        PhosphorIconsDuotone.crop,
                                        color: Colors.white,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        'Crop',
                                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          // Caption field (per file)
          TextField(
            controller: _captionControllers[fileIndex],
            decoration: const InputDecoration(
              hintText: 'Write a caption (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
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
            DogMultiSelectTypeahead(
              dogs: _allDogs,
              selectedDogIds: _selectedDogsByFile[fileIndex],
              onChanged: (updated) {
                setState(() {
                  _selectedDogsByFile[fileIndex] = updated;
                });
              },
            ),
        ],
      ),
    );
  }
}

/// Video player that plays a video from in-memory bytes by writing to a temp file.
class _LocalVideoPlayer extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;

  const _LocalVideoPlayer({required this.bytes, required this.fileName});

  @override
  State<_LocalVideoPlayer> createState() => _LocalVideoPlayerState();
}

class _LocalVideoPlayerState extends State<_LocalVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _isPlaying = false;
  bool _showControls = true;
  bool _hasError = false;
  Timer? _hideTimer;
  File? _tempFile;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.dispose();
    _tempFile?.delete().catchError((_) {});
    super.dispose();
  }

  Future<void> _initializeVideo() async {
    try {
      final dir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _tempFile = File('${dir.path}/p4td_preview_$timestamp\_${widget.fileName}');
      await _tempFile!.writeAsBytes(widget.bytes);

      _controller = VideoPlayerController.file(_tempFile!);
      await _controller!.initialize();
      _controller!.addListener(() {
        if (mounted) setState(() {});
      });
      if (mounted) {
        setState(() => _initialized = true);
      }
    } catch (e) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
    setState(() => _isPlaying = !_isPlaying);
    _showControls = true;
    _startHideTimer();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls && _isPlaying) {
      _startHideTimer();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (_isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showControls = false);
      });
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
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
                widget.fileName,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized) {
      return Container(
        width: double.infinity,
        height: 200,
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return GestureDetector(
      onTap: _toggleControls,
      child: Container(
        color: Colors.black,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: VideoPlayer(_controller!),
            ),
            if (_showControls) ...[
              // Play/pause button
              GestureDetector(
                onTap: _togglePlayPause,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: PhosphorIcon(
                    _isPlaying ? PhosphorIconsDuotone.pause : PhosphorIconsDuotone.play,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
              // Bottom controls bar
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      VideoProgressIndicator(
                        _controller!,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(_controller!.value.position),
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                          Text(
                            _formatDuration(_controller!.value.duration),
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EnlargedImageView extends StatelessWidget {
  final Uint8List bytes;

  const _EnlargedImageView({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Image.memory(bytes),
          ),
        ),
      ),
    );
  }
}
