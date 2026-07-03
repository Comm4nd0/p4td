import 'dog.dart';

enum IntakeRequestStatus { pending, approved, denied }

IntakeRequestStatus parseIntakeRequestStatus(String? value) {
  switch (value) {
    case 'APPROVED':
      return IntakeRequestStatus.approved;
    case 'DENIED':
      return IntakeRequestStatus.denied;
    default:
      return IntakeRequestStatus.pending;
  }
}

extension IntakeRequestStatusExtension on IntakeRequestStatus {
  String get displayName {
    switch (this) {
      case IntakeRequestStatus.pending:
        return 'Pending';
      case IntakeRequestStatus.approved:
        return 'Approved';
      case IntakeRequestStatus.denied:
        return 'Denied';
    }
  }
}

/// One dog on a submitted booking form.
class IntakeDog {
  final int? id;
  final String name;
  final DogSex? sex;
  final DateTime? dateOfBirth;
  final bool isSpayed;
  final String? foodInstructions;
  final String? medicalNotes;
  final String? registeredVet;
  final List<Weekday> daysInDaycare;
  final ScheduleType scheduleType;

  IntakeDog({
    this.id,
    required this.name,
    this.sex,
    this.dateOfBirth,
    this.isSpayed = false,
    this.foodInstructions,
    this.medicalNotes,
    this.registeredVet,
    this.daysInDaycare = const [],
    this.scheduleType = ScheduleType.weekly,
  });

  factory IntakeDog.fromJson(Map<String, dynamic> json) {
    final days = <Weekday>[];
    if (json['daycare_days'] is List) {
      for (final n in json['daycare_days']) {
        if (n is int && n >= 1 && n <= Weekday.values.length) {
          days.add(Weekday.values[n - 1]);
        }
      }
    }
    return IntakeDog(
      id: json['id'],
      name: json['name'] ?? '',
      sex: parseDogSex(json['sex']),
      dateOfBirth: parseApiDate(json['date_of_birth']),
      isSpayed: json['is_spayed'] ?? false,
      foodInstructions: json['food_instructions'],
      medicalNotes: json['medical_notes'],
      registeredVet: json['registered_vet'],
      daysInDaycare: days,
      scheduleType: ScheduleTypeExtension.fromApiValue(json['schedule_type']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (dogSexToApi(sex) != null) 'sex': dogSexToApi(sex),
      if (dateOfBirth != null) 'date_of_birth': formatApiDate(dateOfBirth),
      'is_spayed': isSpayed,
      'food_instructions': foodInstructions ?? '',
      'medical_notes': medicalNotes ?? '',
      'registered_vet': registeredVet ?? '',
      'daycare_days': daysInDaycare.map((d) => d.dayNumber).toList(),
      'schedule_type': scheduleType.apiValue,
    };
  }
}

/// A submitted booking form: the owner's contact details plus the dog(s)
/// they want to enrol in daycare. Staff approve or deny the request.
class IntakeRequest {
  final int id;
  final int? ownerId;
  final String ownerName;
  final String ownerEmail;
  final String? phoneNumber;
  final String? address;
  final String? postcode;
  final String? pickupInstructions;
  final String? additionalInfo;
  final IntakeRequestStatus status;
  final String? denialReason;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final DateTime? createdAt;
  final List<IntakeDog> dogs;

  IntakeRequest({
    required this.id,
    this.ownerId,
    this.ownerName = '',
    this.ownerEmail = '',
    this.phoneNumber,
    this.address,
    this.postcode,
    this.pickupInstructions,
    this.additionalInfo,
    this.status = IntakeRequestStatus.pending,
    this.denialReason,
    this.reviewedByName,
    this.reviewedAt,
    this.createdAt,
    this.dogs = const [],
  });

  factory IntakeRequest.fromJson(Map<String, dynamic> json) {
    return IntakeRequest(
      id: json['id'],
      ownerId: json['owner'],
      ownerName: json['owner_name'] ?? '',
      ownerEmail: json['owner_email'] ?? '',
      phoneNumber: json['phone_number'],
      address: json['address'],
      postcode: json['postcode'],
      pickupInstructions: json['pickup_instructions'],
      additionalInfo: json['additional_info'],
      status: parseIntakeRequestStatus(json['status']),
      denialReason: json['denial_reason'],
      reviewedByName: json['reviewed_by_name'],
      reviewedAt: parseApiDate(json['reviewed_at']),
      createdAt: parseApiDate(json['created_at']),
      dogs: (json['dogs'] as List? ?? [])
          .map((d) => IntakeDog.fromJson(d as Map<String, dynamic>))
          .toList(),
    );
  }

  String get dogNames => dogs.map((d) => d.name).join(', ');
}
