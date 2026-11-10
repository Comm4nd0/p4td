import 'support_message.dart';
import 'api_datetime.dart';

enum QueryStatus {
  open,
  resolved,
}

/// A dog on the account of the person a staff member is talking to — just
/// enough to name it in the conversation header and open its profile.
class QueryOwnerDog {
  final int id;
  final String name;
  final String? profileImageUrl;

  QueryOwnerDog({required this.id, required this.name, this.profileImageUrl});

  factory QueryOwnerDog.fromJson(Map<String, dynamic> json) => QueryOwnerDog(
        id: json['id'],
        name: json['name'] ?? '',
        profileImageUrl: json['profile_image'],
      );
}

class SupportQuery {
  final int id;
  final int ownerId;
  final String ownerName;

  /// Staff-only: the owner's dogs, so staff can see who the thread is about.
  /// Null for owners.
  final List<QueryOwnerDog>? ownerDogs;
  final String subject;
  final QueryStatus status;
  final String? resolvedByName;
  final DateTime? resolvedAt;
  final List<SupportMessage> messages;
  final int messageCount;
  final DateTime? lastMessageAt;
  final bool hasUnreadReply;
  final bool staffHasUnread;
  final DateTime createdAt;
  final DateTime updatedAt;

  SupportQuery({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    this.ownerDogs,
    required this.subject,
    required this.status,
    this.resolvedByName,
    this.resolvedAt,
    this.messages = const [],
    this.messageCount = 0,
    this.lastMessageAt,
    this.hasUnreadReply = false,
    this.staffHasUnread = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SupportQuery.fromJson(Map<String, dynamic> json) {
    return SupportQuery(
      id: json['id'],
      ownerId: (json['owner'] as num?)?.toInt() ?? 0,
      ownerName: json['owner_name'] ?? '',
      ownerDogs: json['owner_dogs'] is List
          ? (json['owner_dogs'] as List)
              .map((d) => QueryOwnerDog.fromJson(d as Map<String, dynamic>))
              .toList()
          : null,
      subject: json['subject'] ?? '',
      status: json['status'] == 'RESOLVED'
          ? QueryStatus.resolved
          : QueryStatus.open,
      resolvedByName: json['resolved_by_name'],
      resolvedAt: parseApiDateTime(json['resolved_at']),
      messages: json['messages'] != null
          ? (json['messages'] as List)
              .map((m) => SupportMessage.fromJson(m))
              .toList()
          : [],
      messageCount: json['message_count'] ?? 0,
      hasUnreadReply: json['has_unread_reply'] ?? false,
      staffHasUnread: json['staff_has_unread'] ?? false,
      lastMessageAt: parseApiDateTime(json['last_message_at']),
      createdAt: requireApiDateTime(json['created_at']),
      updatedAt: requireApiDateTime(json['updated_at']),
    );
  }
}
