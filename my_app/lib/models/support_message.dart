class SupportMessage {
  final String id;
  final String senderId;
  final String senderName;
  final bool isStaff;
  final String text;
  final DateTime createdAt;

  SupportMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.isStaff,
    required this.text,
    required this.createdAt,
  });

  factory SupportMessage.fromJson(Map<String, dynamic> json) {
    return SupportMessage(
      id: json['id'].toString(),
      senderId: json['sender'].toString(),
      senderName: json['sender_name'] ?? '',
      isStaff: json['is_staff'] ?? false,
      text: json['text'] ?? '',
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
