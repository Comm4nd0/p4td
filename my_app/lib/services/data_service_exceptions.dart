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

/// Why two incompatible dogs are being flagged for a day.
enum CompatibilityConflictScope {
  /// Both dogs ride with the same driver — they share the pickup and
  /// drop-off run as well as the day at daycare.
  sameGroup,

  /// The dogs are in the daycare on the same day but under different
  /// drivers. Pickup groups are separate, but they mix once everyone is in.
  sameDay,
}

class CompatibilityConflict {
  final CompatibilityConflictScope scope;

  /// The driver both dogs share. Null for [CompatibilityConflictScope.sameDay].
  final int? staffMemberId;
  final String staffMemberName;
  final int dogAId;
  final String dogAName;

  /// Who drives dog A that day; null when it has no driver yet.
  final String? dogAStaffName;
  final int dogBId;
  final String dogBName;
  final String? dogBStaffName;
  final List<String> reasons;

  CompatibilityConflict({
    this.scope = CompatibilityConflictScope.sameGroup,
    required this.staffMemberId,
    required this.staffMemberName,
    required this.dogAId,
    required this.dogAName,
    this.dogAStaffName,
    required this.dogBId,
    required this.dogBName,
    this.dogBStaffName,
    required this.reasons,
  });

  bool get isSameGroup => scope == CompatibilityConflictScope.sameGroup;

  static int? _optInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }

  factory CompatibilityConflict.fromJson(Map<String, dynamic> json) {
    return CompatibilityConflict(
      scope: json['scope'] == 'SAME_DAY'
          ? CompatibilityConflictScope.sameDay
          : CompatibilityConflictScope.sameGroup,
      staffMemberId: _optInt(json['staff_member_id']),
      staffMemberName: json['staff_member_name']?.toString() ?? '',
      dogAId: _optInt(json['dog_a_id']) ?? 0,
      dogAName: json['dog_a_name']?.toString() ?? '',
      dogAStaffName: json['dog_a_staff_name']?.toString(),
      dogBId: _optInt(json['dog_b_id']) ?? 0,
      dogBName: json['dog_b_name']?.toString() ?? '',
      dogBStaffName: json['dog_b_staff_name']?.toString(),
      reasons: (json['reasons'] as List<dynamic>? ?? [])
          .map((r) => r.toString())
          .toList(),
    );
  }
}
