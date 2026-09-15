/// Which side of the day an owner meets the team on.
enum OwnerHandoverLeg {
  /// The owner brings the dog to daycare in the morning.
  dropOff('DROP_OFF'),

  /// The owner collects the dog from daycare in the evening.
  collection('COLLECTION');

  const OwnerHandoverLeg(this.apiValue);
  final String apiValue;
}

/// One dog an owner is handing over that day, with the expected time when
/// the profile or the day's override gives one ("08:30", else null).
class OwnerHandoverDog {
  final int dogId;
  final String dogName;
  final String? dogProfileImage;
  final String? time;

  const OwnerHandoverDog({
    required this.dogId,
    required this.dogName,
    this.dogProfileImage,
    this.time,
  });

  factory OwnerHandoverDog.fromJson(Map<String, dynamic> json) =>
      OwnerHandoverDog(
        dogId: json['dog_id'] as int,
        dogName: json['dog_name'] as String? ?? '',
        dogProfileImage: json['dog_profile_image'] as String?,
        time: json['time'] as String?,
      );
}

/// One leg of a day's owner handovers: the dogs the owners are bringing (or
/// collecting) and the staff member responsible for meeting them, if anyone
/// has been put on it yet.
class OwnerHandoverLegStatus {
  final OwnerHandoverLeg leg;
  final int count;
  final List<OwnerHandoverDog> dogs;
  final int? staffMemberId;
  final String? staffMemberName;

  const OwnerHandoverLegStatus({
    required this.leg,
    required this.count,
    this.dogs = const [],
    this.staffMemberId,
    this.staffMemberName,
  });

  bool get hasStaff => staffMemberId != null;

  /// Dogs are coming and nobody is down to meet the owners — the red state.
  bool get needsStaff => count > 0 && !hasStaff;

  factory OwnerHandoverLegStatus.fromJson(
      OwnerHandoverLeg leg, Map<String, dynamic>? json) {
    final list = json?['dogs'] as List<dynamic>? ?? [];
    return OwnerHandoverLegStatus(
      leg: leg,
      count: json?['count'] as int? ?? list.length,
      dogs: list
          .map((d) => OwnerHandoverDog.fromJson(d as Map<String, dynamic>))
          .toList(),
      staffMemberId: json?['staff_member_id'] as int?,
      staffMemberName: json?['staff_member_name'] as String?,
    );
  }
}

/// `daily-assignments/owner_handovers/` for one day: both legs.
class OwnerHandoverStatus {
  final OwnerHandoverLegStatus dropOff;
  final OwnerHandoverLegStatus collection;

  const OwnerHandoverStatus({required this.dropOff, required this.collection});

  /// Nothing to show: no owner is bringing or collecting a dog that day.
  bool get isEmpty => dropOff.count == 0 && collection.count == 0;

  OwnerHandoverLegStatus operator [](OwnerHandoverLeg leg) =>
      leg == OwnerHandoverLeg.dropOff ? dropOff : collection;

  factory OwnerHandoverStatus.fromJson(Map<String, dynamic> json) =>
      OwnerHandoverStatus(
        dropOff: OwnerHandoverLegStatus.fromJson(
            OwnerHandoverLeg.dropOff, json['drop_off'] as Map<String, dynamic>?),
        collection: OwnerHandoverLegStatus.fromJson(OwnerHandoverLeg.collection,
            json['collection'] as Map<String, dynamic>?),
      );
}
