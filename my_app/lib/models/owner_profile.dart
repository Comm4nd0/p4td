class OwnerProfile {
  final int userId;
  final String username;
  final String email;
  final String? address;
  final String? phoneNumber;
  final String? pickupInstructions;

  OwnerProfile({
    required this.userId,
    required this.username,
    required this.email,
    this.address,
    this.phoneNumber,
    this.pickupInstructions,
  });

  factory OwnerProfile.fromJson(Map<String, dynamic> json) {
    return OwnerProfile(
      userId: json['user_id'] ?? 0,
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      address: json['address'],
      phoneNumber: json['phone_number'],
      pickupInstructions: json['pickup_instructions'],
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
