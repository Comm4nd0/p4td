
import 'dog.dart';

enum BoardingRequestStatus {
  pending,
  approved,
  denied,
}

class BoardingRequest {
  final int id;
  final int ownerId;
  final String ownerName;
  final List<int> dogIds;
  final List<String> dogNames; // For display convenience
  final DateTime startDate;
  final DateTime endDate;
  final String? specialInstructions;
  final BoardingRequestStatus status;
  final String? approvedByName;
  final DateTime? approvedAt;
  final DateTime createdAt;

  BoardingRequest({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.dogIds,
    required this.dogNames,
    required this.startDate,
    required this.endDate,
    this.specialInstructions,
    required this.status,
    this.approvedByName,
    this.approvedAt,
    required this.createdAt,
  });

  factory BoardingRequest.fromJson(Map<String, dynamic> json) {
    return BoardingRequest(
      id: json['id'],
      ownerId: json['owner'],
      ownerName: json['owner_name'],
      dogIds: List<int>.from(json['dogs']),
      dogNames: List<String>.from(json['dog_names']),
      startDate: DateTime.parse(json['start_date']),
      endDate: DateTime.parse(json['end_date']),
      specialInstructions: json['special_instructions'],
      status: BoardingRequestStatus.values.firstWhere(
        (e) => e.toString().split('.').last.toUpperCase() == json['status'],
        orElse: () => BoardingRequestStatus.pending,
      ),
      approvedByName: json['approved_by_name'],
      approvedAt: json['approved_at'] != null ? DateTime.parse(json['approved_at']) : null,
      createdAt: DateTime.parse(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dogs': dogIds,
      'start_date': startDate.toIso8601String().split('T').first,
      'end_date': endDate.toIso8601String().split('T').first,
      'special_instructions': specialInstructions,
    };
  }
}
