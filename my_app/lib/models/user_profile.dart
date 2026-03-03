class UserProfile {
  final String username;
  final String email;
  final String? address;
  final String? phoneNumber;
  final String? pickupInstructions;
  final String? firstName;
  final String? profilePhotoUrl;
  final bool isStaff;
  final bool canAssignDogs;
  final bool canAddFeedMedia;
  final bool canManageRequests;
  final bool canReplyQueries;
  final bool canApproveTimeoff;

  // Notification preferences
  final bool notifyFeed;
  final bool notifyTraffic;
  final bool notifyBookings;
  final bool notifyDogUpdates;

  UserProfile({
    required this.username,
    required this.email,
    this.address,
    this.phoneNumber,
    this.pickupInstructions,
    this.firstName,
    this.profilePhotoUrl,
    this.isStaff = false,
    this.canAssignDogs = false,
    this.canAddFeedMedia = false,
    this.canManageRequests = false,
    this.canReplyQueries = false,
    this.canApproveTimeoff = false,
    this.notifyFeed = true,
    this.notifyTraffic = true,
    this.notifyBookings = true,
    this.notifyDogUpdates = true,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      username: json['username'],
      email: json['email'],
      address: json['address'],
      phoneNumber: json['phone_number'],
      pickupInstructions: json['pickup_instructions'],
      firstName: json['first_name'],
      profilePhotoUrl: json['profile_photo'],
      isStaff: json['is_staff'] ?? false,
      canAssignDogs: json['can_assign_dogs'] ?? false,
      canAddFeedMedia: json['can_add_feed_media'] ?? false,
      canManageRequests: json['can_manage_requests'] ?? false,
      canReplyQueries: json['can_reply_queries'] ?? false,
      canApproveTimeoff: json['can_approve_timeoff'] ?? false,
      notifyFeed: json['notify_feed'] ?? true,
      notifyTraffic: json['notify_traffic'] ?? true,
      notifyBookings: json['notify_bookings'] ?? true,
      notifyDogUpdates: json['notify_dog_updates'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'first_name': firstName,
      'address': address,
      'phone_number': phoneNumber,
      'pickup_instructions': pickupInstructions,
      'notify_feed': notifyFeed,
      'notify_traffic': notifyTraffic,
      'notify_bookings': notifyBookings,
      'notify_dog_updates': notifyDogUpdates,
    };
  }
}
