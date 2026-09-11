class OwnerProfile {
  final int userId;
  final String username;
  final String firstName;
  final String lastName;
  final String email;
  final String? address;
  final String? phoneNumber;
  final String? pickupInstructions;

  OwnerProfile({
    required this.userId,
    required this.username,
    this.firstName = '',
    this.lastName = '',
    required this.email,
    this.address,
    this.phoneNumber,
    this.pickupInstructions,
  });

  /// What staff know the person as: their name, else the username (which
  /// for accounts created in the app is the email address).
  String get displayName {
    final name = '$firstName $lastName'.trim();
    return name.isNotEmpty ? name : username;
  }

  /// True when every word of [query] appears somewhere in the name, username
  /// or email, so "sue pen", "penney" and "sue@" all find Sue Penney.
  bool matches(String query) {
    final haystack = '$firstName $lastName $username $email'.toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(haystack.contains);
  }

  factory OwnerProfile.fromJson(Map<String, dynamic> json) {
    return OwnerProfile(
      userId: json['user_id'] ?? 0,
      username: json['username'] ?? '',
      firstName: json['first_name'] ?? '',
      lastName: json['last_name'] ?? '',
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
