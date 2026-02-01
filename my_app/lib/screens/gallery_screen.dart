import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import '../models/photo.dart';
import '../services/data_service.dart';

class GalleryScreen extends StatefulWidget {
  final String dogId;
  final bool isStaff;

  const GalleryScreen({super.key, required this.dogId, this.isStaff = false});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final DataService _dataService = ApiDataService();
  late Future<List<Photo>> _photosFuture;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _photosFuture = _dataService.getPhotos(widget.dogId);
  }

  Future<void> _pickAndUploadImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);

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
    final List<XFile> images = await picker.pickMultiImage();

    if (images.isEmpty) return;

    try {
      setState(() => _uploading = true);
      
      final imagesToUpload = <(Uint8List, String, DateTime)>[];
      final now = DateTime.now();
      
      for (final image in images) {
        final imageBytes = await image.readAsBytes();
        imagesToUpload.add((imageBytes, image.name, now));
      }
      
      await _dataService.uploadMultiplePhotos(widget.dogId, imagesToUpload);

      // Refresh the gallery
      setState(() {
        _photosFuture = _dataService.getPhotos(widget.dogId);
        _uploading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${images.length} photos uploaded successfully!')),
        );
      }
    } catch (e) {
      setState(() => _uploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photos: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.isStaff && !_uploading
          ? FloatingActionButton(
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  builder: (context) => Container(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.image),
                          title: const Text('Upload Single Photo'),
                          onTap: () {
                            Navigator.pop(context);
                            _pickAndUploadImage();
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.collections),
                          title: const Text('Upload Multiple Photos'),
                          onTap: () {
                            Navigator.pop(context);
                            _pickAndUploadMultipleImages();
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
              tooltip: 'Upload Photos',
              child: const Icon(Icons.add_photo_alternate),
            )
          : null,
      body: FutureBuilder<List<Photo>>(
        future: _photosFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('No photos found.'));
          }

          final photos = snapshot.data!;
          return GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: photos.length,
            itemBuilder: (context, index) {
              final photo = photos[index];
              return GestureDetector(
                onTap: () {
                  _showFullScreenImage(context, photos, index);
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    photo.url,
                    fit: BoxFit.cover,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showFullScreenImage(BuildContext context, List<Photo> photos, int initialIndex) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FullScreenImageViewer(
        photos: photos,
        initialIndex: initialIndex,
      ),
    ));
  }
}

class FullScreenImageViewer extends StatefulWidget {
  final List<Photo> photos;
  final int initialIndex;

  const FullScreenImageViewer({
    super.key,
    required this.photos,
    required this.initialIndex,
  });

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_currentIndex];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          DateFormat('MMM d, y').format(photo.takenAt),
          style: const TextStyle(color: Colors.white),
        ),
      ),
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
            },
            itemCount: widget.photos.length,
            itemBuilder: (context, index) {
              return Center(
                child: Image.network(widget.photos[index].url),
              );
            },
          ),
          // Page indicators at the bottom
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
    );
  }
}
