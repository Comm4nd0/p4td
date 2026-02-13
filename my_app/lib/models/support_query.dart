import 'support_message.dart';

enum QueryStatus {
  open,
  resolved,
}

class SupportQuery {
  final int id;
  final int ownerId;
  final String ownerName;
  final String subject;
  final QueryStatus status;
  final String? resolvedByName;
  final DateTime? resolvedAt;
  final List<SupportMessage> messages;
  final int messageCount;
  final DateTime? lastMessageAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  SupportQuery({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.subject,
    required this.status,
    this.resolvedByName,
    this.resolvedAt,
    this.messages = const [],
    this.messageCount = 0,
    this.lastMessageAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SupportQuery.fromJson(Map<String, dynamic> json) {
    return SupportQuery(
      id: json['id'],
      ownerId: json['owner'],
      ownerName: json['owner_name'] ?? '',
      subject: json['subject'] ?? '',
      status: json['status'] == 'RESOLVED'
          ? QueryStatus.resolved
          : QueryStatus.open,
      resolvedByName: json['resolved_by_name'],
      resolvedAt: json['resolved_at'] != null
          ? DateTime.parse(json['resolved_at'])
          : null,
      messages: json['messages'] != null
          ? (json['messages'] as List)
              .map((m) => SupportMessage.fromJson(m))
              .toList()
          : [],
      messageCount: json['message_count'] ?? 0,
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'])
          : null,
      createdAt: DateTime.parse(json['created_at']),
      updatedAt: DateTime.parse(json['updated_at']),
    );
  }
}
