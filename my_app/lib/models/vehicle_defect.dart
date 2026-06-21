import 'comment.dart';

class VehicleDefectImage {
  final int id;
  final String? imageUrl;
  final String? thumbnailUrl;

  VehicleDefectImage({
    required this.id,
    this.imageUrl,
    this.thumbnailUrl,
  });

  factory VehicleDefectImage.fromJson(Map<String, dynamic> json) {
    return VehicleDefectImage(
      id: json['id'],
      imageUrl: json['image'],
      thumbnailUrl: json['thumbnail'],
    );
  }
}

class VehicleDefect {
  final int id;
  final int vehicleId;
  final String vehicleName;
  final String title;
  final String? description;

  /// 'LOW' | 'MEDIUM' | 'HIGH'
  final String severity;

  /// 'REPORTED' | 'IN_PROGRESS' | 'RESOLVED'
  final String status;
  final String? reportedByName;
  final String? resolvedByName;
  final DateTime? resolvedAt;
  final List<VehicleDefectImage> images;
  final List<Comment> comments;
  final DateTime createdAt;

  VehicleDefect({
    required this.id,
    required this.vehicleId,
    required this.vehicleName,
    required this.title,
    this.description,
    this.severity = 'MEDIUM',
    this.status = 'REPORTED',
    this.reportedByName,
    this.resolvedByName,
    this.resolvedAt,
    this.images = const [],
    this.comments = const [],
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

  factory VehicleDefect.fromJson(Map<String, dynamic> json) {
    return VehicleDefect(
      id: json['id'],
      vehicleId: json['vehicle'],
      vehicleName: json['vehicle_name'] ?? '',
      title: json['title'] ?? '',
      description: json['description'],
      severity: json['severity'] ?? 'MEDIUM',
      status: json['status'] ?? 'REPORTED',
      reportedByName: json['reported_by_name'],
      resolvedByName: json['resolved_by_name'],
      resolvedAt: json['resolved_at'] != null
          ? DateTime.parse(json['resolved_at'])
          : null,
      images: (json['images'] as List<dynamic>? ?? [])
          .map((i) => VehicleDefectImage.fromJson(i))
          .toList(),
      comments: (json['comments'] as List<dynamic>? ?? [])
          .map((c) => Comment.fromJson(c))
          .toList(),
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
