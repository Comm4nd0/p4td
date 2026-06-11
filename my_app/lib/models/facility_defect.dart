class FacilityDefectImage {
  final int id;
  final String? imageUrl;
  final String? thumbnailUrl;

  FacilityDefectImage({
    required this.id,
    this.imageUrl,
    this.thumbnailUrl,
  });

  factory FacilityDefectImage.fromJson(Map<String, dynamic> json) {
    return FacilityDefectImage(
      id: json['id'],
      imageUrl: json['image'],
      thumbnailUrl: json['thumbnail'],
    );
  }
}

class FacilityDefect {
  final int id;
  final String title;
  final String? location;
  final String? description;

  /// 'LOW' | 'MEDIUM' | 'HIGH'
  final String severity;

  /// 'REPORTED' | 'IN_PROGRESS' | 'RESOLVED'
  final String status;
  final String? reportedByName;
  final String? resolvedByName;
  final DateTime? resolvedAt;
  final List<FacilityDefectImage> images;
  final DateTime createdAt;

  FacilityDefect({
    required this.id,
    required this.title,
    this.location,
    this.description,
    this.severity = 'MEDIUM',
    this.status = 'REPORTED',
    this.reportedByName,
    this.resolvedByName,
    this.resolvedAt,
    this.images = const [],
    required this.createdAt,
  });

  bool get isResolved => status == 'RESOLVED';

  String get statusLabel {
    switch (status) {
      case 'IN_PROGRESS':
        return 'In Progress';
      case 'RESOLVED':
        return 'Resolved';
      default:
        return 'Reported';
    }
  }

  String get severityLabel {
    switch (severity) {
      case 'LOW':
        return 'Low';
      case 'HIGH':
        return 'High';
      default:
        return 'Medium';
    }
  }

  factory FacilityDefect.fromJson(Map<String, dynamic> json) {
    return FacilityDefect(
      id: json['id'],
      title: json['title'] ?? '',
      location: json['location'],
      description: json['description'],
      severity: json['severity'] ?? 'MEDIUM',
      status: json['status'] ?? 'REPORTED',
      reportedByName: json['reported_by_name'],
      resolvedByName: json['resolved_by_name'],
      resolvedAt: json['resolved_at'] != null
          ? DateTime.parse(json['resolved_at'])
          : null,
      images: (json['images'] as List<dynamic>? ?? [])
          .map((i) => FacilityDefectImage.fromJson(i))
          .toList(),
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
