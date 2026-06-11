import 'package:flutter/material.dart' show TimeOfDay;

enum Weekday {
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  // Note: saturday and sunday removed - daycare only operates Mon-Fri
}

enum DogSex { male, female }

DogSex? parseDogSex(dynamic value) {
  if (value == null) return null;
  switch (value.toString().toUpperCase()) {
    case 'M':
      return DogSex.male;
    case 'F':
      return DogSex.female;
    default:
      return null;
  }
}

String? dogSexToApi(DogSex? sex) {
  switch (sex) {
    case DogSex.male:
      return 'M';
    case DogSex.female:
      return 'F';
    case null:
      return null;
  }
}

DateTime? parseApiDate(dynamic value) {
  if (value == null) return null;
  final s = value.toString();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

String? formatApiDate(DateTime? d) {
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Parse a backend time string ("HH:MM:SS" or "HH:MM") to TimeOfDay.
TimeOfDay? parseApiTime(dynamic value) {
  if (value == null) return null;
  final parts = value.toString().split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return TimeOfDay(hour: h, minute: m);
}

/// Format a TimeOfDay as "HH:MM" for API submission.
String formatApiTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

extension WeekdayExtension on Weekday {
  String get displayName {
    return name[0].toUpperCase() + name.substring(1);
  }

  int get dayNumber {
    return index + 1; // Monday = 1, ..., Sunday = 7
  }
}

class OwnerDetails {
  final int userId;
  final String username;
  final String email;
  final String? firstName;
  final String? phoneNumber;
  final String? pickupInstructions;

  OwnerDetails({
    required this.userId,
    required this.username,
    required this.email,
    this.firstName,
    this.phoneNumber,
    this.pickupInstructions,
  });

  /// Friendly display name: first name when set, otherwise username.
  String get displayName =>
      (firstName != null && firstName!.isNotEmpty) ? firstName! : username;

  factory OwnerDetails.fromJson(Map<String, dynamic> json) {
    return OwnerDetails(
      userId: json['user_id'] ?? 0,
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      firstName: json['first_name'],
      phoneNumber: json['phone_number'],
      pickupInstructions: json['pickup_instructions'],
    );
  }
}

enum DropoffTime {
  after1530,
  after1600,
}

extension DropoffTimeExtension on DropoffTime {
  String get displayName {
    switch (this) {
      case DropoffTime.after1530:
        return 'After 15:30';
      case DropoffTime.after1600:
        return 'After 16:00';
    }
  }

  String get apiValue {
    switch (this) {
      case DropoffTime.after1530:
        return 'after_1530';
      case DropoffTime.after1600:
        return 'after_1600';
    }
  }

  static DropoffTime? fromApiValue(String? value) {
    switch (value) {
      case 'after_1530':
        return DropoffTime.after1530;
      case 'after_1600':
        return DropoffTime.after1600;
      default:
        return null;
    }
  }
}

enum ScheduleType {
  weekly,
  fortnightly,
  adHoc,
}

extension ScheduleTypeExtension on ScheduleType {
  String get displayName {
    switch (this) {
      case ScheduleType.weekly:
        return 'Weekly';
      case ScheduleType.fortnightly:
        return 'Fortnightly';
      case ScheduleType.adHoc:
        return 'Ad Hoc';
    }
  }

  String get apiValue {
    switch (this) {
      case ScheduleType.weekly:
        return 'weekly';
      case ScheduleType.fortnightly:
        return 'fortnightly';
      case ScheduleType.adHoc:
        return 'ad_hoc';
    }
  }

  static ScheduleType fromApiValue(String? value) {
    switch (value) {
      case 'fortnightly':
        return ScheduleType.fortnightly;
      case 'ad_hoc':
        return ScheduleType.adHoc;
      default:
        return ScheduleType.weekly;
    }
  }
}

class Dog {
  final String id;
  final String name;
  final String ownerId;
  final String? profileImageUrl;
  final String? foodInstructions;
  final String? medicalNotes;
  final String? registeredVet;
  final String? address;
  final List<Weekday> daysInDaycare;
  final OwnerDetails? ownerDetails;
  final List<OwnerDetails> additionalOwners;
  final DropoffTime? preferredDropoffTime;
  final ScheduleType scheduleType;
  final bool ownerBringsDefault;
  final bool ownerCollectsDefault;
  final TimeOfDay? ownerBringsDefaultTime;
  final TimeOfDay? ownerCollectsDefaultTime;
  final DogSex? sex;
  final DateTime? dateOfBirth;
  final bool isSpayed;

  Dog({
    required this.id,
    required this.name,
    required this.ownerId,
    this.profileImageUrl,
    this.foodInstructions,
    this.medicalNotes,
    this.registeredVet,
    this.address,
    this.daysInDaycare = const [],
    this.ownerDetails,
    this.additionalOwners = const [],
    this.preferredDropoffTime,
    this.scheduleType = ScheduleType.weekly,
    this.ownerBringsDefault = false,
    this.ownerCollectsDefault = false,
    this.ownerBringsDefaultTime,
    this.ownerCollectsDefaultTime,
    this.sex,
    this.dateOfBirth,
    this.isSpayed = false,
  });

  /// All owners (primary + additional) for convenience
  List<OwnerDetails> get allOwners {
    final owners = <OwnerDetails>[];
    if (ownerDetails != null) owners.add(ownerDetails!);
    owners.addAll(additionalOwners);
    return owners;
  }

  /// True when staff need to chase the owner about spay status:
  /// male, over 1 year old, and not marked spayed.
  bool get needsSpayPrompt {
    if (sex != DogSex.male || isSpayed || dateOfBirth == null) return false;
    return DateTime.now().difference(dateOfBirth!).inDays > 365;
  }

  Dog copyWith({
    String? id,
    String? name,
    String? ownerId,
    String? profileImageUrl,
    String? foodInstructions,
    String? medicalNotes,
    String? registeredVet,
    String? address,
    List<Weekday>? daysInDaycare,
    OwnerDetails? ownerDetails,
    List<OwnerDetails>? additionalOwners,
    DropoffTime? preferredDropoffTime,
    ScheduleType? scheduleType,
    bool? ownerBringsDefault,
    bool? ownerCollectsDefault,
    TimeOfDay? ownerBringsDefaultTime,
    TimeOfDay? ownerCollectsDefaultTime,
    DogSex? sex,
    DateTime? dateOfBirth,
    bool? isSpayed,
  }) {
    return Dog(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      foodInstructions: foodInstructions ?? this.foodInstructions,
      medicalNotes: medicalNotes ?? this.medicalNotes,
      registeredVet: registeredVet ?? this.registeredVet,
      address: address ?? this.address,
      daysInDaycare: daysInDaycare ?? this.daysInDaycare,
      ownerDetails: ownerDetails ?? this.ownerDetails,
      additionalOwners: additionalOwners ?? this.additionalOwners,
      preferredDropoffTime: preferredDropoffTime ?? this.preferredDropoffTime,
      scheduleType: scheduleType ?? this.scheduleType,
      ownerBringsDefault: ownerBringsDefault ?? this.ownerBringsDefault,
      ownerCollectsDefault: ownerCollectsDefault ?? this.ownerCollectsDefault,
      ownerBringsDefaultTime: ownerBringsDefaultTime ?? this.ownerBringsDefaultTime,
      ownerCollectsDefaultTime: ownerCollectsDefaultTime ?? this.ownerCollectsDefaultTime,
      sex: sex ?? this.sex,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      isSpayed: isSpayed ?? this.isSpayed,
    );
  }
}
