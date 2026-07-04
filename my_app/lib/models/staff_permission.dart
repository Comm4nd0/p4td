class StaffPermission {
  final int userId;
  final String username;
  final String? firstName;
  final String email;
  final bool isSuperuser;
  bool canAssignDogs;
  bool canAddFeedMedia;
  bool canManageRequests;
  bool canReplyQueries;
  bool canApproveTimeoff;
  bool canViewInquiries;
  bool canManageVehicles;
  bool canManagePayments;
  bool canManageBoarding;

  StaffPermission({
    required this.userId,
    required this.username,
    required this.email,
    this.firstName,
    this.isSuperuser = false,
    this.canAssignDogs = false,
    this.canAddFeedMedia = false,
    this.canManageRequests = false,
    this.canReplyQueries = false,
    this.canApproveTimeoff = false,
    this.canViewInquiries = false,
    this.canManageVehicles = false,
    this.canManagePayments = false,
    this.canManageBoarding = false,
  });

  String get displayName {
    final name = firstName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return username;
  }

  factory StaffPermission.fromJson(Map<String, dynamic> json) {
    return StaffPermission(
      userId: json['user_id'],
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      firstName: json['first_name'],
      isSuperuser: json['is_superuser'] ?? false,
      canAssignDogs: json['can_assign_dogs'] ?? false,
      canAddFeedMedia: json['can_add_feed_media'] ?? false,
      canManageRequests: json['can_manage_requests'] ?? false,
      canReplyQueries: json['can_reply_queries'] ?? false,
      canApproveTimeoff: json['can_approve_timeoff'] ?? false,
      canViewInquiries: json['can_view_inquiries'] ?? false,
      canManageVehicles: json['can_manage_vehicles'] ?? false,
      canManagePayments: json['can_manage_payments'] ?? false,
      canManageBoarding: json['can_manage_boarding'] ?? false,
    );
  }
}
