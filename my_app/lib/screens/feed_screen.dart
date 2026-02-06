import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/group_media.dart';
import '../services/data_service.dart';
import '../widgets/feed_item_card.dart';

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

    // Show options
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(context, 'camera_photo'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose Photo'),
              onTap: () => Navigator.pop(context, 'gallery_photo'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Record Video'),
              onTap: () => Navigator.pop(context, 'camera_video'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('Choose Video'),
              onTap: () => Navigator.pop(context, 'gallery_video'),
            ),
             const Divider(),
            ListTile(
              leading: const Icon(Icons.library_add),
              title: const Text('Upload Multiple Photos'),
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
    final isVideo = choice.contains('video');
    final source = choice.contains('camera') ? ImageSource.camera : ImageSource.gallery;

    if (isVideo) {
      file = await picker.pickVideo(source: source);
    } else {
      file = await picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
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
        isVideo: isVideo,
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
    return FeedItemCard(
      media: media,
      isStaff: widget.isStaff,
      onDelete: _deleteMedia,
      onReaction: (mediaId, emoji) => _toggleReaction(mediaId, emoji),
      onComment: (mediaId, text) => _addComment(mediaId, text),
    );
  }

  Future<void> _addComment(String mediaId, String text) async {
    try {
      await _dataService.addComment(mediaId, text);
      _loadFeed(); // Refresh to show new comment
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding comment: $e')),
        );
      }
    }
  }

  Future<void> _toggleReaction(String mediaId, String emoji) async {
    try {
      final updatedMedia = await _dataService.toggleReaction(mediaId, emoji);
      setState(() {
        final index = _feed.indexWhere((m) => m.id == mediaId);
        if (index != -1) {
          _feed[index] = updatedMedia;
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}
