enum ClosureType {
  closed,
  reduced;

  String get apiValue {
    switch (this) {
      case ClosureType.closed:
        return 'CLOSED';
      case ClosureType.reduced:
        return 'REDUCED';
    }
  }

  String get displayName {
    switch (this) {
      case ClosureType.closed:
        return 'Closed';
      case ClosureType.reduced:
        return 'Reduced Capacity';
    }
  }

  static ClosureType fromApi(String value) {
    switch (value) {
      case 'REDUCED':
        return ClosureType.reduced;
      default:
        return ClosureType.closed;
    }
  }
}

class ClosureDay {
  final int id;
  final DateTime date;
  final ClosureType closureType;
  final String reason;
  final String? createdByName;

  ClosureDay({
    required this.id,
    required this.date,
    required this.closureType,
    this.reason = '',
    this.createdByName,
  });

  factory ClosureDay.fromJson(Map<String, dynamic> json) {
    return ClosureDay(
      id: json['id'],
      date: DateTime.parse(json['date']),
      closureType: ClosureType.fromApi(json['closure_type'] ?? 'CLOSED'),
      reason: json['reason'] ?? '',
      createdByName: json['created_by_name'],
    );
  }
}
