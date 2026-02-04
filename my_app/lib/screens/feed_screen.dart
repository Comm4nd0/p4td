import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import '../models/group_media.dart';
import '../services/data_service.dart';

class FeedScreen extends StatefulWidget {
  final bool isStaff;

  const FeedScreen({super.key, required this.isStaff});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final _dataService = ApiDataService();
  List<GroupMedia> _feed = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  Future<void> _loadFeed() async {
    setState(() => _loading = true);
    try {
      final feed = await _dataService.getFeed();
      if (mounted) {
        setState(() {
          _feed = feed;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load feed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _uploadMedia() async {
    final picker = ImagePicker();

    // Show options for photo, video, or multiple photos
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('Upload Photo'),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Upload Video'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Upload Multiple Photos'),
              subtitle: const Text('Select several photos at once'),
              onTap: () => Navigator.pop(context, 'multiple'),
            ),
          ],
        ),
      ),
    );

    if (choice == null) return;

    // Handle multiple photos upload
    if (choice == 'multiple') {
      await _uploadMultiplePhotos(picker);
      return;
    }

    XFile? file;
    if (choice == 'photo') {
      file = await picker.pickImage(source: ImageSource.gallery);
    } else {
      file = await picker.pickVideo(source: ImageSource.gallery);
    }

    if (file == null) return;

    // Show caption dialog
    final caption = await _showCaptionDialog();
    if (caption == null) return; // User cancelled

    // Upload
    try {
      _showUploadingDialog();
      final bytes = await file.readAsBytes();
      await _dataService.uploadGroupMedia(
        fileBytes: bytes,
        fileName: file.name,
        isVideo: choice == 'video',
        caption: caption.isEmpty ? null : caption,
      );
      if (mounted) {
        Navigator.pop(context); // Close uploading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload successful!'), backgroundColor: Colors.green),
        );
        _loadFeed();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close uploading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _uploadMultiplePhotos(ImagePicker picker) async {
    // Pick multiple images
    final files = await picker.pickMultiImage();
    if (files.isEmpty) return;

    // Show caption dialog
    final caption = await _showCaptionDialog();
    if (caption == null) return; // User cancelled

    // Prepare files
    final fileData = <(Uint8List, String)>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      fileData.add((bytes, file.name));
    }

    // Show progress dialog
    int completed = 0;
    final total = files.length;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Uploading $completed/$total photos...'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: total > 0 ? completed / total : 0),
              ],
            ),
          );
        },
      ),
    );

    try {
      await _dataService.uploadMultipleGroupMedia(
        files: fileData,
        caption: caption.isEmpty ? null : caption,
        onProgress: (done, count) {
          completed = done;
          // Update progress - need to rebuild dialog
          if (mounted) {
            Navigator.pop(context);
            if (done < count) {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => AlertDialog(
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text('Uploading $done/$count photos...'),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: done / count),
                    ],
                  ),
                ),
              );
            }
          }
        },
      );
      if (mounted) {
        Navigator.pop(context); // Close final dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully uploaded $total photos!'),
            backgroundColor: Colors.green,
          ),
        );
        _loadFeed();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed after $completed/$total: $e'),
            backgroundColor: Colors.red,
          ),
        );
        if (completed > 0) _loadFeed(); // Refresh to show any that succeeded
      }
    }
  }

  Future<String?> _showCaptionDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Caption'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Write a caption (optional)',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
  }

  void _showUploadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Uploading...'),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMedia(GroupMedia media) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Media'),
        content: const Text('Are you sure you want to delete this?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _dataService.deleteGroupMedia(media.id);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted'), backgroundColor: Colors.green),
      );
      _loadFeed();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feed'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFeed,
          ),
        ],
      ),
      floatingActionButton: widget.isStaff
          ? FloatingActionButton.extended(
              onPressed: _uploadMedia,
              icon: const Icon(Icons.add),
              label: const Text('Upload'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _feed.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'No posts yet',
                        style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                      ),
                      if (widget.isStaff) ...[
                        const SizedBox(height: 8),
                        const Text('Tap the button below to upload photos or videos'),
                      ],
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadFeed,
                  child: ListView.builder(
                    itemCount: _feed.length,
                    itemBuilder: (context, index) {
                      final media = _feed[index];
                      return _buildMediaCard(media);
                    },
                  ),
                ),
    );
  }

  Widget _buildMediaCard(GroupMedia media) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.blue[100],
                  child: Text(
                    media.uploadedByName.isNotEmpty ? media.uploadedByName[0].toUpperCase() : '?',
                    style: TextStyle(color: Colors.blue[800]),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        media.uploadedByName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        DateFormat('d MMM yyyy, HH:mm').format(media.createdAt),
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (widget.isStaff)
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'delete') {
                        _deleteMedia(media);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, color: Colors.red),
                            SizedBox(width: 8),
                            Text('Delete'),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          // Media content
          if (media.isPhoto)
            Image.network(
              media.fileUrl,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                height: 200,
                color: Colors.grey[300],
                child: const Center(child: Icon(Icons.error)),
              ),
            )
          else
            _VideoPlayer(url: media.fileUrl, thumbnail: media.thumbnailUrl),
          // Caption
          if (media.caption != null && media.caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(media.caption!),
            ),
        ],
      ),
    );
  }
}

class _VideoPlayer extends StatefulWidget {
  final String url;
  final String? thumbnail;

  const _VideoPlayer({required this.url, this.thumbnail});

  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
  VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _initialized = false;

  @override
  void dispose() {
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
    }
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
              Image.network(
                widget.thumbnail!,
                width: double.infinity,
                height: 250,
                fit: BoxFit.cover,
              )
            else
              Container(
                width: double.infinity,
                height: 250,
                color: Colors.black,
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(50),
              ),
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        if (_isPlaying) {
          _controller!.pause();
        } else {
          _controller!.play();
        }
        setState(() => _isPlaying = !_isPlaying);
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: VideoPlayer(_controller!),
          ),
          if (!_isPlaying)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(50),
              ),
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
            ),
        ],
      ),
    );
  }
}
