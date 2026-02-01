import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/photo.dart';
import '../services/data_service.dart';

class GalleryScreen extends StatefulWidget {
  final String dogId;

  const GalleryScreen({super.key, required this.dogId});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final DataService _dataService = ApiDataService();
  late Future<List<Photo>> _photosFuture;

  @override
  void initState() {
    super.initState();
    _photosFuture = _dataService.getPhotos(widget.dogId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Photo>>(
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
                _showFullScreenImage(context, photo);
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
    );
  }

  void _showFullScreenImage(BuildContext context, Photo photo) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            DateFormat('MMM d, y').format(photo.takenAt),
            style: const TextStyle(color: Colors.white),
          ),
        ),
        backgroundColor: Colors.black,
        body: Center(
          child: Image.network(photo.url),
        ),
      ),
    ));
  }
}
