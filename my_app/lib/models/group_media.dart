enum MediaType { photo, video }

class GroupMedia {
  final String id;
  final String uploadedBy;
  final String uploadedByName;
  final MediaType mediaType;
  final String fileUrl;
  final String? thumbnailUrl;
  final String? caption;
  final DateTime createdAt;

  GroupMedia({
    required this.id,
    required this.uploadedBy,
    required this.uploadedByName,
    required this.mediaType,
    required this.fileUrl,
    this.thumbnailUrl,
    this.caption,
    required this.createdAt,
  });

  factory GroupMedia.fromJson(Map<String, dynamic> json) {
    return GroupMedia(
      id: json['id'].toString(),
      uploadedBy: json['uploaded_by'].toString(),
      uploadedByName: json['uploaded_by_name'] ?? '',
      mediaType: json['media_type'] == 'VIDEO' ? MediaType.video : MediaType.photo,
      fileUrl: json['file'],
      thumbnailUrl: json['thumbnail'],
      caption: json['caption'],
      createdAt: DateTime.parse(json['created_at']),
    );
  }

  bool get isVideo => mediaType == MediaType.video;
  bool get isPhoto => mediaType == MediaType.photo;
}
