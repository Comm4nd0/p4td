import 'comment.dart';

enum MediaType { photo, video }

class TaggedDog {
  final String id;
  final String name;
  final String? profileImageUrl;

  TaggedDog({required this.id, required this.name, this.profileImageUrl});

  factory TaggedDog.fromJson(Map<String, dynamic> json) {
    return TaggedDog(
      id: json['id'].toString(),
      name: json['name'] ?? '',
      profileImageUrl: json['profile_image'],
    );
  }
}

class GroupMedia {
  final String id;
  final String uploadedBy;
  final String uploadedByName;
  final String? uploadedByProfilePhoto;
  final MediaType mediaType;
  final String fileUrl;
  final String? thumbnailUrl;
  final String? caption;
  final List<TaggedDog> taggedDogs;
  final Map<String, int> reactions;
  final String? userReaction;
  final List<Comment> comments;
  final DateTime createdAt;

  GroupMedia({
    required this.id,
    required this.uploadedBy,
    required this.uploadedByName,
    this.uploadedByProfilePhoto,
    required this.mediaType,
    required this.fileUrl,
    this.thumbnailUrl,
    this.caption,
    this.taggedDogs = const [],
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
      uploadedByProfilePhoto: json['uploaded_by_profile_photo'],
      mediaType: json['media_type'] == 'VIDEO' ? MediaType.video : MediaType.photo,
      fileUrl: json['file'],
      thumbnailUrl: json['thumbnail'],
      caption: json['caption'],
      taggedDogs: (json['tagged_dogs'] as List? ?? [])
          .map((d) => TaggedDog.fromJson(d))
          .toList(),
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
