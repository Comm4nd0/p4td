import 'package:flutter/material.dart' show TimeOfDay;
import 'dog.dart' show parseApiTime, parseApiDouble;

/// Scope used when reassigning or unassigning a single dog on a specific date.
/// Maps to the backend `scope` body param on /reassign/ and /unassign/.
enum AssignmentScope {
  justThisDay,
  fromNowOn;

  String get apiValue {
    switch (this) {
      case AssignmentScope.justThisDay:
        return 'just_this_day';
      case AssignmentScope.fromNowOn:
        return 'from_now_on';
    }
  }
}

/// Scope used when bulk-swapping one staff member's pickups to another.
/// Maps to the backend `scope` body param on /swap_staff/.
enum SwapScope {
  justThisDay,
  thisWeekdayForever,
  allWeekdaysForever;

  String get apiValue {
    switch (this) {
      case SwapScope.justThisDay:
        return 'just_this_day';
      case SwapScope.thisWeekdayForever:
        return 'this_weekday_forever';
      case SwapScope.allWeekdaysForever:
        return 'all_weekdays_forever';
    }
  }
}

enum AssignmentStatus {
  assigned,
  pickedUp,
  droppedOff;

  String get apiValue {
    switch (this) {
      case AssignmentStatus.assigned:
        return 'ASSIGNED';
      case AssignmentStatus.pickedUp:
        return 'PICKED_UP';
      case AssignmentStatus.droppedOff:
        return 'DROPPED_OFF';
    }
  }

  String get displayName {
    switch (this) {
      case AssignmentStatus.assigned:
        return 'Assigned';
      case AssignmentStatus.pickedUp:
        return 'With Team';
      case AssignmentStatus.droppedOff:
        return 'Dropped Off';
    }
  }

  static AssignmentStatus fromApi(String value) {
    switch (value) {
      case 'PICKED_UP':
        return AssignmentStatus.pickedUp;
      case 'DROPPED_OFF':
        return AssignmentStatus.droppedOff;
      default:
        return AssignmentStatus.assigned;
    }
  }
}

class DailyDogAssignment {
  final int id;
  final int dogId;
  final String dogName;
  final String? dogProfileImage;
  /// Cached pickup coordinates of the dog (from its geocoded address). Null when
  /// the dog has no address — the map pins it at base.
  final double? latitude;
  final double? longitude;
  final int staffMemberId;
  final String staffMemberName;
  final String ownerName;
  final String? ownerAddress;
  final String? ownerPhone;
  final String? pickupInstructions;
  final DateTime date;
  final AssignmentStatus status;
  final bool isBoarding;
  final bool? ownerBrings;
  final bool? ownerCollects;
  final TimeOfDay? ownerBringsTime;
  final TimeOfDay? ownerCollectsTime;
  final bool effectiveOwnerBrings;
  final bool effectiveOwnerCollects;
  final TimeOfDay? effectiveOwnerBringsTime;
  final TimeOfDay? effectiveOwnerCollectsTime;
  final int sortOrder;

  DailyDogAssignment({
    required this.id,
    required this.dogId,
    required this.dogName,
    this.dogProfileImage,
    this.latitude,
    this.longitude,
    required this.staffMemberId,
    required this.staffMemberName,
    required this.ownerName,
    this.ownerAddress,
    this.ownerPhone,
    this.pickupInstructions,
    required this.date,
    required this.status,
    this.isBoarding = false,
    this.ownerBrings,
    this.ownerCollects,
    this.ownerBringsTime,
    this.ownerCollectsTime,
    this.effectiveOwnerBrings = false,
    this.effectiveOwnerCollects = false,
    this.effectiveOwnerBringsTime,
    this.effectiveOwnerCollectsTime,
    this.sortOrder = 0,
  });

  factory DailyDogAssignment.fromJson(Map<String, dynamic> json) {
    return DailyDogAssignment(
      id: json['id'],
      dogId: json['dog'] is int ? json['dog'] : int.parse(json['dog'].toString()),
      dogName: json['dog_name'] ?? '',
      dogProfileImage: json['dog_profile_image'],
      latitude: parseApiDouble(json['latitude']),
      longitude: parseApiDouble(json['longitude']),
      staffMemberId: json['staff_member'] is int ? json['staff_member'] : int.parse(json['staff_member'].toString()),
      staffMemberName: json['staff_member_name'] ?? '',
      ownerName: json['owner_name'] ?? '',
      ownerAddress: json['owner_address'],
      ownerPhone: json['owner_phone'],
      pickupInstructions: json['pickup_instructions'],
      date: DateTime.parse(json['date']),
      status: AssignmentStatus.fromApi(json['status'] ?? 'ASSIGNED'),
      isBoarding: json['is_boarding'] ?? false,
      ownerBrings: json['owner_brings'],
      ownerCollects: json['owner_collects'],
      ownerBringsTime: parseApiTime(json['owner_brings_time']),
      ownerCollectsTime: parseApiTime(json['owner_collects_time']),
      effectiveOwnerBrings: json['effective_owner_brings'] ?? false,
      effectiveOwnerCollects: json['effective_owner_collects'] ?? false,
      effectiveOwnerBringsTime: parseApiTime(json['effective_owner_brings_time']),
      effectiveOwnerCollectsTime: parseApiTime(json['effective_owner_collects_time']),
      sortOrder: json['sort_order'] ?? 0,
    );
  }

  DailyDogAssignment copyWith({
    AssignmentStatus? status,
    bool? ownerBrings,
    bool? ownerCollects,
    TimeOfDay? ownerBringsTime,
    TimeOfDay? ownerCollectsTime,
    bool? effectiveOwnerBrings,
    bool? effectiveOwnerCollects,
    TimeOfDay? effectiveOwnerBringsTime,
    TimeOfDay? effectiveOwnerCollectsTime,
    int? sortOrder,
  }) {
    return DailyDogAssignment(
      id: id,
      dogId: dogId,
      dogName: dogName,
      dogProfileImage: dogProfileImage,
      latitude: latitude,
      longitude: longitude,
      staffMemberId: staffMemberId,
      staffMemberName: staffMemberName,
      ownerName: ownerName,
      ownerAddress: ownerAddress,
      ownerPhone: ownerPhone,
      pickupInstructions: pickupInstructions,
      date: date,
      status: status ?? this.status,
      isBoarding: isBoarding,
      ownerBrings: ownerBrings ?? this.ownerBrings,
      ownerCollects: ownerCollects ?? this.ownerCollects,
      ownerBringsTime: ownerBringsTime ?? this.ownerBringsTime,
      ownerCollectsTime: ownerCollectsTime ?? this.ownerCollectsTime,
      effectiveOwnerBrings: effectiveOwnerBrings ?? this.effectiveOwnerBrings,
      effectiveOwnerCollects: effectiveOwnerCollects ?? this.effectiveOwnerCollects,
      effectiveOwnerBringsTime: effectiveOwnerBringsTime ?? this.effectiveOwnerBringsTime,
      effectiveOwnerCollectsTime: effectiveOwnerCollectsTime ?? this.effectiveOwnerCollectsTime,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

/// Result of an assign-dogs call. Contains the newly created assignments
/// plus any dogs that were skipped because they were already assigned.
class AssignDogsResult {
  final List<DailyDogAssignment> created;
  final List<SkippedDog> skipped;

  AssignDogsResult({required this.created, this.skipped = const []});

  bool get hasSkipped => skipped.isNotEmpty;
}

class SkippedDog {
  final String dogName;
  final String reason;

  SkippedDog({required this.dogName, required this.reason});

  factory SkippedDog.fromJson(Map<String, dynamic> json) {
    return SkippedDog(
      dogName: json['dog'] ?? '',
      reason: json['reason'] ?? 'Already assigned',
    );
  }
}
