class UserProfile {
  final String username;
  final String email;
  final String? address;
  final String? phoneNumber;
  final String? pickupInstructions;
  final String? firstName;
  final bool isStaff;
  final bool canAssignDogs;

  UserProfile({
    required this.username,
    required this.email,
    this.address,
    this.phoneNumber,
    this.pickupInstructions,
    this.firstName,
    this.isStaff = false,
    this.canAssignDogs = false,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      username: json['username'],
      email: json['email'],
      address: json['address'],
      phoneNumber: json['phone_number'],
      pickupInstructions: json['pickup_instructions'],
      firstName: json['first_name'],
      isStaff: json['is_staff'] ?? false,
      canAssignDogs: json['can_assign_dogs'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'first_name': firstName,
      'address': address,
      'phone_number': phoneNumber,
      'pickup_instructions': pickupInstructions,
    };
  }
}
