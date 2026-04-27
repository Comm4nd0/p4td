/// Represents a pending change to a dog's profile that needs staff approval.
class DogProfileChangeRequest {
  final int id;
  final int dogId;
  final String dogName;
  final String? dogProfileImage;
  final int requestedById;
  final String requestedByName;
  final Map<String, dynamic> proposedChanges;
  final String? proposedImage;
  final bool deleteImage;
  final String status; // PENDING, APPROVED, REJECTED
  final int? reviewedById;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final DateTime createdAt;

  DogProfileChangeRequest({
    required this.id,
    required this.dogId,
    required this.dogName,
    this.dogProfileImage,
    required this.requestedById,
    required this.requestedByName,
    required this.proposedChanges,
    this.proposedImage,
    this.deleteImage = false,
    required this.status,
    this.reviewedById,
    this.reviewedByName,
    this.reviewedAt,
    required this.createdAt,
  });

  bool get isPending => status == 'PENDING';
  bool get isApproved => status == 'APPROVED';
  bool get isRejected => status == 'REJECTED';

  String get statusDisplay {
    switch (status) {
      case 'PENDING':
        return 'Pending';
      case 'APPROVED':
        return 'Approved';
      case 'REJECTED':
        return 'Rejected';
      default:
        return status;
    }
  }

  /// Human-readable summary of what changed.
  String get changesSummary {
    final parts = <String>[];
    final fieldLabels = {
      'name': 'Name',
      'food_instructions': 'Food instructions',
      'medical_notes': 'Medical notes',
      'daycare_days': 'Daycare schedule',
      'schedule_type': 'Schedule type',
    };
    for (final key in proposedChanges.keys) {
      parts.add(fieldLabels[key] ?? key);
    }
    if (proposedImage != null) parts.add('Profile photo');
    if (deleteImage) parts.add('Remove photo');
    return parts.isEmpty ? 'No changes' : parts.join(', ');
  }

  factory DogProfileChangeRequest.fromJson(Map<String, dynamic> json) {
    return DogProfileChangeRequest(
      id: json['id'],
      dogId: json['dog'] is int ? json['dog'] : int.parse(json['dog'].toString()),
      dogName: json['dog_name'] ?? '',
      dogProfileImage: json['dog_profile_image'],
      requestedById: json['requested_by'] is int
          ? json['requested_by']
          : int.parse(json['requested_by'].toString()),
      requestedByName: json['requested_by_name'] ?? '',
      proposedChanges: (json['proposed_changes'] as Map<String, dynamic>?) ?? {},
      proposedImage: json['proposed_image'],
      deleteImage: json['delete_image'] ?? false,
      status: json['status'] ?? 'PENDING',
      reviewedById: json['reviewed_by'],
      reviewedByName: json['reviewed_by_name'],
      reviewedAt: json['reviewed_at'] != null
          ? DateTime.parse(json['reviewed_at'])
          : null,
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
