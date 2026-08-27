/// A dog attending on a given day that hasn't yet been tagged in any feed
/// media posted that day, with the staff member responsible for it.
class UntaggedDog {
  final int dogId;
  final String dogName;
  final String? dogProfileImage;
  final int staffMemberId;
  final String staffMemberName;

  const UntaggedDog({
    required this.dogId,
    required this.dogName,
    this.dogProfileImage,
    required this.staffMemberId,
    required this.staffMemberName,
  });

  factory UntaggedDog.fromJson(Map<String, dynamic> json) {
    return UntaggedDog(
      dogId: json['dog_id'],
      dogName: json['dog_name'] ?? '',
      dogProfileImage: json['dog_profile_image'],
      staffMemberId: json['staff_member_id'],
      staffMemberName: json['staff_member_name'] ?? '',
    );
  }
}

/// Day-level photo tagging progress: how many of the day's dogs appear tagged
/// in feed media posted that day. Drives the dashboard card that nudges staff
/// to have pictured every dog by the end of the day.
class PhotoTaggingStatus {
  final int total;
  final int tagged;
  final List<UntaggedDog> untagged;

  const PhotoTaggingStatus({
    required this.total,
    required this.tagged,
    required this.untagged,
  });

  bool get complete => total > 0 && tagged >= total;

  factory PhotoTaggingStatus.fromJson(Map<String, dynamic> json) {
    final list = json['untagged'] as List<dynamic>? ?? [];
    return PhotoTaggingStatus(
      total: json['total'] ?? 0,
      tagged: json['tagged'] ?? 0,
      untagged: list
          .map((d) => UntaggedDog.fromJson(d as Map<String, dynamic>))
          .toList(),
    );
  }
}
