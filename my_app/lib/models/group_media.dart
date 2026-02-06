import 'comment.dart';

enum MediaType { photo, video }

class GroupMedia {
  final String id;
  final String uploadedBy;
  final String uploadedByName;
  final MediaType mediaType;
  final String fileUrl;
  final String? thumbnailUrl;
  final String? caption;
  final Map<String, int> reactions;
  final String? userReaction;
  final List<Comment> comments;
  final DateTime createdAt;

  GroupMedia({
    required this.id,
    required this.uploadedBy,
    required this.uploadedByName,
    required this.mediaType,
    required this.fileUrl,
    this.thumbnailUrl,
    this.caption,
    required this.reactions,
    this.userReaction,
    required this.comments,
    required this.createdAt,
  });

  factory GroupMedia.fromJson(Map<String, dynamic> json) {
    Map<String, int> reactionsMap = {};
    if (json['reactions'] != null) {
      (json['reactions'] as Map<String, dynamic>).forEach((key, value) {
        reactionsMap[key] = value as int;
      });
    }

    return GroupMedia(
      id: json['id'].toString(),
      uploadedBy: json['uploaded_by'].toString(),
      uploadedByName: json['uploaded_by_name'] ?? '',
      mediaType: json['media_type'] == 'VIDEO' ? MediaType.video : MediaType.photo,
      fileUrl: json['file'],
      thumbnailUrl: json['thumbnail'],
      caption: json['caption'],
      reactions: reactionsMap,
      userReaction: json['user_reaction'],
      comments: (json['comments'] as List? ?? [])
          .map((c) => Comment.fromJson(c))
          .toList(),
      createdAt: DateTime.parse(json['created_at']),
    );
  }

  bool get isVideo => mediaType == MediaType.video;
  bool get isPhoto => mediaType == MediaType.photo;
}
