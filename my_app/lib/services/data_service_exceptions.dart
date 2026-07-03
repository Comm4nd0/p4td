part of 'data_service.dart';

/// Thrown when a dog update is submitted for staff approval instead of applied
/// directly.  The caller should show a confirmation message rather than an error.
class DogUpdatePendingApprovalException implements Exception {
  final String message;
  DogUpdatePendingApprovalException([this.message = 'Your changes have been submitted for approval.']);
  @override
  String toString() => message;
}

class UnspayedMaleSummary {
  final String id;
  final String name;
  final String? imageUrl;
  UnspayedMaleSummary({required this.id, required this.name, this.imageUrl});
}

/// One page of feed items plus whether more pages follow.
class FeedPage {
  final List<gm.GroupMedia> items;
  final bool hasMore;
  const FeedPage({required this.items, required this.hasMore});
}

class UnspayedMalesResult {
  final int count;
  final List<UnspayedMaleSummary> dogs;
  UnspayedMalesResult({required this.count, required this.dogs});
}

class CompatibilityConflict {
  final int staffMemberId;
  final String staffMemberName;
  final int dogAId;
  final String dogAName;
  final int dogBId;
  final String dogBName;
  final List<String> reasons;

  CompatibilityConflict({
    required this.staffMemberId,
    required this.staffMemberName,
    required this.dogAId,
    required this.dogAName,
    required this.dogBId,
    required this.dogBName,
    required this.reasons,
  });

  factory CompatibilityConflict.fromJson(Map<String, dynamic> json) {
    return CompatibilityConflict(
      staffMemberId: json['staff_member_id'] is int
          ? json['staff_member_id']
          : int.parse(json['staff_member_id'].toString()),
      staffMemberName: json['staff_member_name']?.toString() ?? '',
      dogAId: json['dog_a_id'] is int ? json['dog_a_id'] : int.parse(json['dog_a_id'].toString()),
      dogAName: json['dog_a_name']?.toString() ?? '',
      dogBId: json['dog_b_id'] is int ? json['dog_b_id'] : int.parse(json['dog_b_id'].toString()),
      dogBName: json['dog_b_name']?.toString() ?? '',
      reasons: (json['reasons'] as List<dynamic>? ?? [])
          .map((r) => r.toString())
          .toList(),
    );
  }
}
