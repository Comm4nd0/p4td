enum MediaType { photo, video }

class Photo {
  final String id;
  final String dogId;
  final String url;
  final String? thumbnailUrl;
  final MediaType mediaType;
  final DateTime takenAt;

  Photo({
    required this.id,
    required this.dogId,
    required this.url,
    this.thumbnailUrl,
    this.mediaType = MediaType.photo,
    required this.takenAt,
  });

  bool get isVideo => mediaType == MediaType.video;
}
