/// A dog that is in on a given day and whose birthday it is — what the staff
/// dashboard shows so the team remembers the birthday photo.
class DogBirthday {
  final int dogId;
  final String dogName;
  final String? dogProfileImage;

  /// The age the dog turns on the day.
  final int age;

  /// In on an approved boarding stay that day (weekends have no board row).
  final bool boarding;

  /// Who has the dog that day; empty when nobody is named yet.
  final String staffMemberName;

  /// Already tagged in a feed post made that day.
  final bool photographed;

  const DogBirthday({
    required this.dogId,
    required this.dogName,
    this.dogProfileImage,
    required this.age,
    this.boarding = false,
    this.staffMemberName = '',
    this.photographed = false,
  });

  factory DogBirthday.fromJson(Map<String, dynamic> json) {
    return DogBirthday(
      dogId: json['dog_id'],
      dogName: json['dog_name'] ?? '',
      dogProfileImage: json['dog_profile_image'],
      age: json['age'] ?? 0,
      boarding: json['boarding'] ?? false,
      staffMemberName: json['staff_member_name'] ?? '',
      photographed: json['photographed'] ?? false,
    );
  }

  /// "3rd", "11th", "22nd".
  String get ordinalAge {
    final tens = age % 100;
    if (tens >= 11 && tens <= 13) return '${age}th';
    switch (age % 10) {
      case 1:
        return '${age}st';
      case 2:
        return '${age}nd';
      case 3:
        return '${age}rd';
      default:
        return '${age}th';
    }
  }
}
