part of 'data_service.dart';

/// Thrown when a dog update is submitted for staff approval instead of applied
/// directly.  The caller should show a confirmation message rather than an error.
class DogUpdatePendingApprovalException implements Exception {
  final String message;
  DogUpdatePendingApprovalException([this.message = 'Your changes have been submitted for approval.']);
  @override
  String toString() => message;
}

/// A dog on the staff dashboard's "Dog health to confirm" list.
class FlaggedDogSummary {
  final String id;
  final String name;
  final String? imageUrl;

  /// Set for the vaccinations-overdue list: the date that is over a year old.
  final DateTime? lastVaccinationDate;

  const FlaggedDogSummary({
    required this.id,
    required this.name,
    this.imageUrl,
    this.lastVaccinationDate,
  });
}

/// One page of feed items plus whether more pages follow.
class FeedPage {
  final List<gm.GroupMedia> items;
  final bool hasMore;
  const FeedPage({required this.items, required this.hasMore});
}

/// `GET /api/dogs/health_flags/`: every dog whose health paperwork needs a
/// word with the owner, for one dashboard row. [count] is the grand total.
class DogHealthFlags {
  final int count;
  final List<FlaggedDogSummary> unspayedMales;
  final List<FlaggedDogSummary> vaccinationsOverdue;

  const DogHealthFlags({
    required this.count,
    required this.unspayedMales,
    required this.vaccinationsOverdue,
  });

  const DogHealthFlags.empty()
      : count = 0,
        unspayedMales = const [],
        vaccinationsOverdue = const [];
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
