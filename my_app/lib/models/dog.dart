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

class Dog {
  final String id;
  final String name;
  final String breed;
  final String ownerId;
  final String? profileImageUrl;
  final String? foodInstructions;
  final String? medicalNotes;
  final List<Weekday> daysInDaycare;

  Dog({
    required this.id,
    required this.name,
    required this.breed,
    required this.ownerId,
    this.profileImageUrl,
    this.foodInstructions,
    this.medicalNotes,
    this.daysInDaycare = const [],
  });

  Dog copyWith({
    String? id,
    String? name,
    String? breed,
    String? ownerId,
    String? profileImageUrl,
    String? foodInstructions,
    String? medicalNotes,
    List<Weekday>? daysInDaycare,
  }) {
    return Dog(
      id: id ?? this.id,
      name: name ?? this.name,
      breed: breed ?? this.breed,
      ownerId: ownerId ?? this.ownerId,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      foodInstructions: foodInstructions ?? this.foodInstructions,
      medicalNotes: medicalNotes ?? this.medicalNotes,
      daysInDaycare: daysInDaycare ?? this.daysInDaycare,
    );
  }
}
