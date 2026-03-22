class ContactInquiry {
  final int id;
  final String name;
  final String email;
  final String service;
  final String serviceDisplay;
  final String message;
  final bool isRead;
  final DateTime createdAt;

  ContactInquiry({
    required this.id,
    required this.name,
    required this.email,
    required this.service,
    required this.serviceDisplay,
    required this.message,
    required this.isRead,
    required this.createdAt,
  });

  factory ContactInquiry.fromJson(Map<String, dynamic> json) {
    return ContactInquiry(
      id: json['id'],
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      service: json['service'] ?? '',
      serviceDisplay: json['service_display'] ?? '',
      message: json['message'] ?? '',
      isRead: json['is_read'] ?? false,
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
