enum AssignmentStatus {
  assigned,
  pickedUp,
  atDaycare,
  droppedOff;

  String get apiValue {
    switch (this) {
      case AssignmentStatus.assigned:
        return 'ASSIGNED';
      case AssignmentStatus.pickedUp:
        return 'PICKED_UP';
      case AssignmentStatus.atDaycare:
        return 'AT_DAYCARE';
      case AssignmentStatus.droppedOff:
        return 'DROPPED_OFF';
    }
  }

  String get displayName {
    switch (this) {
      case AssignmentStatus.assigned:
        return 'Assigned';
      case AssignmentStatus.pickedUp:
        return 'Picked Up';
      case AssignmentStatus.atDaycare:
        return 'At Daycare';
      case AssignmentStatus.droppedOff:
        return 'Dropped Off';
    }
  }

  static AssignmentStatus fromApi(String value) {
    switch (value) {
      case 'PICKED_UP':
        return AssignmentStatus.pickedUp;
      case 'AT_DAYCARE':
        return AssignmentStatus.atDaycare;
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
  final int staffMemberId;
  final String staffMemberName;
  final String ownerName;
  final String? ownerAddress;
  final String? ownerPhone;
  final String? pickupInstructions;
  final DateTime date;
  final AssignmentStatus status;

  DailyDogAssignment({
    required this.id,
    required this.dogId,
    required this.dogName,
    this.dogProfileImage,
    required this.staffMemberId,
    required this.staffMemberName,
    required this.ownerName,
    this.ownerAddress,
    this.ownerPhone,
    this.pickupInstructions,
    required this.date,
    required this.status,
  });

  factory DailyDogAssignment.fromJson(Map<String, dynamic> json) {
    return DailyDogAssignment(
      id: json['id'],
      dogId: json['dog'] is int ? json['dog'] : int.parse(json['dog'].toString()),
      dogName: json['dog_name'] ?? '',
      dogProfileImage: json['dog_profile_image'],
      staffMemberId: json['staff_member'] is int ? json['staff_member'] : int.parse(json['staff_member'].toString()),
      staffMemberName: json['staff_member_name'] ?? '',
      ownerName: json['owner_name'] ?? '',
      ownerAddress: json['owner_address'],
      ownerPhone: json['owner_phone'],
      pickupInstructions: json['pickup_instructions'],
      date: DateTime.parse(json['date']),
      status: AssignmentStatus.fromApi(json['status'] ?? 'ASSIGNED'),
    );
  }

  DailyDogAssignment copyWith({AssignmentStatus? status}) {
    return DailyDogAssignment(
      id: id,
      dogId: dogId,
      dogName: dogName,
      dogProfileImage: dogProfileImage,
      staffMemberId: staffMemberId,
      staffMemberName: staffMemberName,
      ownerName: ownerName,
      ownerAddress: ownerAddress,
      ownerPhone: ownerPhone,
      pickupInstructions: pickupInstructions,
      date: date,
      status: status ?? this.status,
    );
  }
}
