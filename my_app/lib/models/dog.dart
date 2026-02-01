enum Weekday {
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday,
}

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

  OwnerDetails({
    required this.userId,
    required this.username,
    required this.email,
  });

  factory OwnerDetails.fromJson(Map<String, dynamic> json) {
    return OwnerDetails(
      userId: json['user_id'] ?? 0,
      username: json['username'] ?? '',
      email: json['email'] ?? '',
    );
  }
}

class Dog {
  final String id;
  final String name;
  final String ownerId;
  final String? profileImageUrl;
  final String? foodInstructions;
  final String? medicalNotes;
  final List<Weekday> daysInDaycare;
  final OwnerDetails? ownerDetails;

  Dog({
    required this.id,
    required this.name,
    required this.ownerId,
    this.profileImageUrl,
    this.foodInstructions,
    this.medicalNotes,
    this.daysInDaycare = const [],
    this.ownerDetails,
  });

  Dog copyWith({
    String? id,
    String? name,
    String? ownerId,
    String? profileImageUrl,
    String? foodInstructions,
    String? medicalNotes,
    List<Weekday>? daysInDaycare,
    OwnerDetails? ownerDetails,
  }) {
    return Dog(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      foodInstructions: foodInstructions ?? this.foodInstructions,
      medicalNotes: medicalNotes ?? this.medicalNotes,
      daysInDaycare: daysInDaycare ?? this.daysInDaycare,
      ownerDetails: ownerDetails ?? this.ownerDetails,
    );
  }
}
