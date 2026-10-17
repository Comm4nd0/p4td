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

  /// Set for the certificates-missing list: 'MISSING' or 'EXPIRED', since
  /// when, when the owners were last pushed about it, and whether anyone on
  /// the app owns the dog (Send reminder has someone to reach).
  final String? certificateStatus;
  final DateTime? certificateNeededSince;
  final DateTime? certificateReminderLastSent;
  final bool canRemind;

  const FlaggedDogSummary({
    required this.id,
    required this.name,
    this.imageUrl,
    this.lastVaccinationDate,
    this.certificateStatus,
    this.certificateNeededSince,
    this.certificateReminderLastSent,
    this.canRemind = false,
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
  /// Dogs with no vet certificate on file evidencing a vaccination in the
  /// last year — the ones the owner is being chased about.
  final List<FlaggedDogSummary> certificatesMissing;

  const DogHealthFlags({
    required this.count,
    required this.unspayedMales,
    required this.vaccinationsOverdue,
    this.certificatesMissing = const [],
  });

  const DogHealthFlags.empty()
      : count = 0,
        unspayedMales = const [],
        vaccinationsOverdue = const [],
        certificatesMissing = const [];
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

/// One dog in a [CompatibilityConflict], with who drives it that day.
class ConflictDog {
  final int id;
  final String name;

  /// Null when the dog has no driver yet.
  final String? staffName;

  const ConflictDog({required this.id, required this.name, this.staffName});
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

  /// Every dog in the conflict: the pair, or all of a group note's dogs
  /// (fine in any smaller mix, not all together). [dogAId]/[dogBId] are its
  /// first two. Built from the pair when the server sends no list.
  final List<ConflictDog> dogs;

  /// Who on the team has said "I've seen this and I'm handling it" today,
  /// and when. Null until someone does. The dashboard spotlights a pair
  /// until it is acknowledged; the banner shows it either way.
  final String? acknowledgedByName;
  final DateTime? acknowledgedAt;

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
    List<ConflictDog>? dogs,
    this.acknowledgedByName,
    this.acknowledgedAt,
  }) : dogs = dogs ??
            [
              ConflictDog(id: dogAId, name: dogAName, staffName: dogAStaffName),
              ConflictDog(id: dogBId, name: dogBName, staffName: dogBStaffName),
            ];

  bool get isGroup => dogs.length > 2;

  /// "Rex + Buddy", or "Rex + Buddy + Max" for a group.
  String get dogNames => dogs.map((d) => d.name).join(' + ');

  bool get isSameGroup => scope == CompatibilityConflictScope.sameGroup;
  bool get isAcknowledged => acknowledgedByName != null;

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
      dogs: json['dogs'] is List
          ? (json['dogs'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map((d) => ConflictDog(
                    id: _optInt(d['id']) ?? 0,
                    name: d['name']?.toString() ?? '',
                    staffName: d['staff_name']?.toString(),
                  ))
              .toList()
          : null,
      acknowledgedByName: json['acknowledged_by_name']?.toString(),
      acknowledgedAt: json['acknowledged_at'] != null
          ? DateTime.tryParse(json['acknowledged_at'].toString())
          : null,
    );
  }
}
