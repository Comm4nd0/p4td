import 'dart:async';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'dart:typed_data';
import '../models/photo.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';

class GalleryScreen extends StatefulWidget {
  final String dogId;
  final bool isStaff;

  final bool embed;

  const GalleryScreen({
    super.key, 
    required this.dogId, 
    this.isStaff = false,
    this.embed = false,
  });

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final DataService _dataService = getIt<DataService>();
  late Future<List<Photo>> _photosFuture;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _photosFuture = _dataService.getPhotos(widget.dogId);
  }



  Future<void> _pickAndUploadImage() async {

    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 85,
    );

    if (image == null) return;

    try {
      setState(() => _uploading = true);
      
      final imageBytes = await image.readAsBytes();
      final now = DateTime.now();
      
      await _dataService.uploadPhoto(
        widget.dogId,
        imageBytes,
        image.name,
        now,
      );

      // Refresh the gallery
      setState(() {
        _photosFuture = _dataService.getPhotos(widget.dogId);
        _uploading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo uploaded successfully!')),
        );
      }
    } catch (e) {
      setState(() => _uploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: $e')),
        );
      }
    }
  }

  Future<void> _pickAndUploadMultipleImages() async {
    final ImagePicker picker = ImagePicker();
    // Downscale/re-encode in the native picker so full-resolution library
    // originals (5–15MB each, HEIC on iOS) never hit the network — same
    // limits as the single-photo path. Keeps memory flat on older phones and
    // turns multi-minute uploads into seconds.
    final List<XFile> images = await picker.pickMultiImage(
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 85,
    );

    if (images.isEmpty) return;

    final imagesToUpload = <(Uint8List, String, DateTime)>[];
    final now = DateTime.now();
    for (final image in images) {
      imagesToUpload.add((await image.readAsBytes(), image.name, now));
    }

    await _uploadPhotoBatch(imagesToUpload);
  }

  /// Uploads a batch with a progress dialog, then reports the outcome
  /// honestly — including which files failed, with a Retry for just those.
  Future<void> _uploadPhotoBatch(List<(Uint8List, String, DateTime)> batch) async {
    if (!mounted) return;
    setState(() => _uploading = true);

    final total = batch.length;
    final progress = ValueNotifier<int>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (context, completed, _) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Uploading $completed/$total...'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: total > 0 ? completed / total : 0),
              ],
            ),
          ),
        ),
      ),
    );

    PhotoBatchResult result;
    try {
      result = await _dataService.uploadMultiplePhotos(
        widget.dogId,
        batch,
        onProgress: (done, _) => progress.value = done,
      );
    } catch (e) {
      result = (
        uploaded: const <Photo>[],
        failures: [
          for (var i = 0; i < batch.length; i++)
            (index: i, fileName: batch[i].$2, error: e),
        ],
      );
    }

    if (!mounted) return;
    Navigator.pop(context); // Close progress dialog

    setState(() {
      if (result.uploaded.isNotEmpty) {
        _photosFuture = _dataService.getPhotos(widget.dogId);
      }
      _uploading = false;
    });

    final failures = result.failures;
    if (failures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$total photo${total == 1 ? '' : 's'} uploaded successfully!')),
      );
      return;
    }

    final failedBatch = [for (final f in failures) batch[f.index]];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Uploaded ${result.uploaded.length}/$total. '
          '${failures.length} failed — check your connection.',
        ),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Retry',
          onPressed: () => _uploadPhotoBatch(failedBatch),
        ),
      ),
    );
  }

  Future<void> _pickAndUploadVideo() async {
    final ImagePicker picker = ImagePicker();
    final XFile? video = await picker.pickVideo(source: ImageSource.gallery);

    if (video == null) return;

    try {
      setState(() => _uploading = true);
      
      final videoBytes = await video.readAsBytes();
      final now = DateTime.now();
      
      await _dataService.uploadPhoto(
        widget.dogId,
        videoBytes,
        video.name,
        now,
      );

      // Refresh the gallery
      setState(() {
        _photosFuture = _dataService.getPhotos(widget.dogId);
        _uploading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video uploaded successfully!')),
        );
      }
    } catch (e) {
      setState(() => _uploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload video: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embed) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isStaff)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: ElevatedButton.icon(
                onPressed: _uploading ? null : _showUploadOptions,
                icon: _uploading 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) 
                  : Picon(PiconsDuotone.images),
                label: Text(_uploading ? 'Uploading...' : 'Add Photo/Video'),
              ),
            ),
          _buildGalleryContent(),
        ],
      );
    }

    return Scaffold(
      floatingActionButton: widget.isStaff && !_uploading
          ? FloatingActionButton(
              onPressed: _showUploadOptions,
              child: Picon(PiconsDuotone.images),
            )
          : null,
      body: _buildGalleryContent(),
    );
  }

  void _showUploadOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Picon(PiconsDuotone.images),
              title: const Text('Upload Single Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadImage();
              },
            ),
            ListTile(
              leading: Picon(PiconsDuotone.images),
              title: const Text('Upload Multiple Photos'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadMultipleImages();
              },
            ),
            ListTile(
              leading: Picon(PiconsDuotone.videoCamera),
              title: const Text('Upload Video'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadVideo();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryContent() {
    return FutureBuilder<List<Photo>>(
      future: _photosFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
        } else if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(32.0),
            child: Center(child: Text('No photos yet.')),
          );
        }

        final photos = snapshot.data!;
        // Sort by takenAt descending (newest first)
        photos.sort((a, b) => b.takenAt.compareTo(a.takenAt));

        // Size the decoded bitmap to the grid cell (3 columns) so we don't
        // decode full-resolution images for tiny thumbnails.
        final media = MediaQuery.of(context);
        final cellWidth = (media.size.width - 4 * 2 - 4 * 2) / 3;
        final cellCacheWidth = (media.devicePixelRatio * cellWidth).round();

        return GridView.builder(
          padding: const EdgeInsets.all(4),
          shrinkWrap: widget.embed,
          physics: widget.embed ? const NeverScrollableScrollPhysics() : null,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: photos.length,
          itemBuilder: (context, index) {
            final photo = photos[index];
            return GestureDetector(
              onTap: () {
                _showFullScreenImage(context, photos, index);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (photo.isVideo && photo.thumbnailUrl == null)
                      Container(color: Colors.grey[800])
                    else
                      CachedNetworkImage(
                        imageUrl: photo.isVideo && photo.thumbnailUrl != null
                          ? photo.thumbnailUrl!
                          : (photo.thumbnailUrl ?? photo.url),
                        memCacheWidth: cellCacheWidth,
                        fit: BoxFit.cover,
                        errorWidget: (context, url, error) => Container(color: Colors.grey[200], child: Picon(PiconsDuotone.warningCircle)),
                      ),
                    if (photo.isVideo)
                      Container(
                        color: Colors.black26,
                        child: Picon(PiconsFill.playCircle, color: Colors.white),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showFullScreenImage(BuildContext context, List<Photo> photos, int initialIndex) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FullScreenImageViewer(
        photos: photos,
        initialIndex: initialIndex,
        onRefresh: () {
          setState(() {
            _photosFuture = _dataService.getPhotos(widget.dogId);
          });
        },
      ),
    ));
  }
}

class FullScreenImageViewer extends StatefulWidget {
  final List<Photo> photos;
  final int initialIndex;
  final VoidCallback? onRefresh;

  const FullScreenImageViewer({
    super.key,
    required this.photos,
    required this.initialIndex,
    this.onRefresh,
  });

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;
  final TextEditingController _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          ukDate(photo.takenAt),
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  onPageChanged: (index) {
                    setState(() => _currentIndex = index);
                  },
                  itemCount: widget.photos.length,
                  itemBuilder: (context, index) {
                    final photo = widget.photos[index];
                    if (photo.isVideo) {
                      return VideoViewer(url: photo.url, thumbnail: photo.thumbnailUrl);
                    } else {
                      return InteractiveViewer(
                        minScale: 1.0,
                        maxScale: 4.0,
                        child: Center(
                          child: CachedNetworkImage(
                            imageUrl: photo.url,
                            placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                            errorWidget: (context, url, error) => Picon(PiconsDuotone.warningCircle),
                          ),
                        ),
                      );
                    }
                  },
                ),
                // Page indicators
                if (widget.photos.length > 1)
                  Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          widget.photos.length,
                          (index) => Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: index == _currentIndex
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
class VideoViewer extends StatefulWidget {
  final String url;
  final String? thumbnail;

  const VideoViewer({super.key, required this.url, this.thumbnail});

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _initialized = false;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    await _controller!.initialize();
    if (mounted) {
      setState(() => _initialized = true);
      _controller!.play();
      setState(() => _isPlaying = true);
      _startHideTimer();
    }
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
    setState(() => _isPlaying = !_isPlaying);
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
    if (!_initialized) {
      return GestureDetector(
        onTap: _initializeVideo,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.thumbnail != null)
              CachedNetworkImage(
                imageUrl: widget.thumbnail!,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  color: Colors.grey[200],
                ),
                errorWidget: (context, url, error) => Container(
                  color: Colors.grey[300],
                  child: Center(child: Picon(PiconsDuotone.warningCircle)),
                ),
              )
            else
              Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.black,
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(50),
              ),
              child: Picon(PiconsDuotone.play, color: Colors.white, size: 48),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: _toggleControls,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: VideoPlayer(_controller!),
          ),
          // Controls overlay
          if (_showControls) ...[
            // Play/pause button
            GestureDetector(
              onTap: _togglePlayPause,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(50),
                ),
                child: Picon(
                  _isPlaying ? PiconsDuotone.pause : PiconsDuotone.play,
                  color: Colors.white,
                  size: 48,
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
                padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
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
                    const SizedBox(height: 4),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _controller!,
                      builder: (context, value, _) => Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(value.position),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                          ),
                          Text(
                            _formatDuration(value.duration),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}