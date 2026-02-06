import 'comment.dart';

enum MediaType { photo, video }

class Photo {
  final String id;
  final String dogId;
  final String url;
  final String? thumbnailUrl;
  final MediaType mediaType;
  final DateTime takenAt;
  final List<Comment> comments;

  Photo({
    required this.id,
    required this.dogId,
    required this.url,
    this.thumbnailUrl,
    this.mediaType = MediaType.photo,
    required this.takenAt,
    required this.comments,
  });

  factory Photo.fromJson(Map<String, dynamic> json) {
    return Photo(
      id: json['id'].toString(),
      dogId: json['dog'].toString(),
      url: json['file'],
      thumbnailUrl: json['thumbnail'],
      mediaType: json['media_type'] == 'VIDEO' ? MediaType.video : MediaType.photo,
      takenAt: DateTime.parse(json['taken_at']),
      comments: (json['comments'] as List? ?? [])
          .map((c) => Comment.fromJson(c))
          .toList(),
    );
  }

  bool get isVideo => mediaType == MediaType.video;
}
