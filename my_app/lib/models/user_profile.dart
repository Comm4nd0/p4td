class UserProfile {
  final String username;
  final String email;
  final String? address;
  final String? phoneNumber;
  final String? pickupInstructions;
  final bool isStaff;

  UserProfile({
    required this.username,
    required this.email,
    this.address,
    this.phoneNumber,
    this.pickupInstructions,
    this.isStaff = false,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      username: json['username'],
      email: json['email'],
      address: json['address'],
      phoneNumber: json['phone_number'],
      pickupInstructions: json['pickup_instructions'],
      isStaff: json['is_staff'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'address': address,
      'phone_number': phoneNumber,
      'pickup_instructions': pickupInstructions,
    };
  }
}
