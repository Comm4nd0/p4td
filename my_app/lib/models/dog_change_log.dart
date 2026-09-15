/// One field that changed, as the API renders it: display strings on both
/// sides, so the app never has to know what a field's raw value looks like.
class DogFieldChange {
  final String field;
  final String label;
  final String oldValue;
  final String newValue;

  const DogFieldChange({
    required this.field,
    required this.label,
    required this.oldValue,
    required this.newValue,
  });

  factory DogFieldChange.fromJson(Map<String, dynamic> json) => DogFieldChange(
        field: json['field']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        oldValue: json['old']?.toString() ?? '',
        newValue: json['new']?.toString() ?? '',
      );
}

/// A row of `/api/dog-change-logs/`: who changed what on a dog, and when.
/// Staff-only — the diffs carry staff-written fields.
class DogChangeLog {
  final int id;

  /// Null once the dog has been deleted; [dogName] still names it.
  final String? dogId;
  final String dogName;
  final String? dogProfileImage;

  /// "First Last" of who made the change, or "System" for a sync/command.
  final String actorName;

  /// CREATED | UPDATED | DELETED | OWNER_CHANGED | VACCINATION | PHOTO | NOTE
  final String action;
  final String actionDisplay;

  /// APP | OWNER_REQUEST | BOOKING_FORM | ADMIN | SYSTEM
  final String source;
  final String sourceDisplay;
  final String summary;
  final List<DogFieldChange> changes;
  final DateTime createdAt;

  const DogChangeLog({
    required this.id,
    this.dogId,
    required this.dogName,
    this.dogProfileImage,
    required this.actorName,
    required this.action,
    required this.actionDisplay,
    this.source = 'APP',
    this.sourceDisplay = 'App',
    required this.summary,
    this.changes = const [],
    required this.createdAt,
  });

  bool get isDeleted => action == 'DELETED';

  factory DogChangeLog.fromJson(Map<String, dynamic> json) => DogChangeLog(
        id: json['id'],
        dogId: json['dog']?.toString(),
        dogName: json['dog_name'] ?? '',
        dogProfileImage: json['dog_profile_image'],
        actorName: json['actor_name'] ?? 'System',
        action: json['action'] ?? 'UPDATED',
        actionDisplay: json['action_display'] ?? '',
        source: json['source'] ?? 'APP',
        sourceDisplay: json['source_display'] ?? '',
        summary: json['summary'] ?? '',
        changes: ((json['changes'] as List<dynamic>?) ?? const [])
            .map((c) => DogFieldChange.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
        createdAt: DateTime.parse(json['created_at']),
      );
}
