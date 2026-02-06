class Comment {
  final String id;
  final String user;
  final String userName;
  final String text;
  final DateTime createdAt;

  Comment({
    required this.id,
    required this.user,
    required this.userName,
    required this.text,
    required this.createdAt,
  });

  factory Comment.fromJson(Map<String, dynamic> json) {
    return Comment(
      id: json['id'].toString(),
      user: json['user'].toString(),
      userName: json['user_name'] ?? '',
      text: json['text'] ?? '',
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
