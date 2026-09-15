import '../utils/date_formats.dart';

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

/// The kinds of change the log records, in the order the filter lists them.
const Map<String, String> dogChangeActionLabels = {
  'CREATED': 'Added',
  'UPDATED': 'Updated',
  'OWNER_CHANGED': 'Owner changed',
  'VACCINATION': 'Vaccination',
  'PHOTO': 'Gallery',
  'NOTE': 'Note',
  'MESSAGE': 'Message',
  'APPROVED': 'Approved',
  'DENIED': 'Denied',
  'STATUS': 'Status changed',
  'COMMENT': 'Comment',
  'ASSIGNED': 'Assignment',
  'COMPLETED': 'Check completed',
  'DELETED': 'Deleted',
};

/// The areas of the business the log covers, in the order the filter lists
/// them. `STAFF` and `BILLING` only reach managers — the API drops them for
/// everyone else.
const Map<String, String> dogChangeCategoryLabels = {
  'DOG': 'Dogs',
  'COMMS': 'Client communications',
  'CLIENTS': 'Client accounts',
  'BOOKINGS': 'Booking requests',
  'SCHEDULE': 'Daycare schedule',
  'FLEET': 'Fleet',
  'INCIDENT': 'Incidents',
  'DEFECT': 'Site defects',
  'STAFF': 'Staff',
  'COMPLIANCE': 'Safety & compliance',
  'BILLING': 'Billing',
  'SETTINGS': 'Settings',
};

/// A row of `/api/dog-change-logs/`: the business activity log — who did
/// what, and when. Staff-only — the diffs carry staff-written fields.
///
/// Every entry has a [subject]: the dog for a dog entry, otherwise what it is
/// about (a client, a vehicle, a check, a staff member). Only entries with a
/// [dogId] belong on that dog's profile.
class DogChangeLog {
  final int id;

  /// One of [dogChangeCategoryLabels]' keys.
  final String category;
  final String categoryDisplay;

  /// What the entry is about — the dog's name on a dog entry.
  final String subject;

  /// Null once the dog has been deleted, and on entries not about a dog;
  /// [dogName] still names it (the same value as [subject]).
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
    this.category = 'DOG',
    this.categoryDisplay = 'Dogs',
    String? subject,
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
  }) : subject = subject ?? dogName;

  bool get isDeleted => action == 'DELETED';

  /// A dog entry: the profile's trail, and the rows that read "Buddy — …".
  bool get isAboutDog => category == 'DOG';

  factory DogChangeLog.fromJson(Map<String, dynamic> json) => DogChangeLog(
        id: json['id'],
        category: json['category'] ?? 'DOG',
        categoryDisplay: json['category_display'] ?? dogChangeCategoryLabels[json['category']] ?? 'Dogs',
        subject: json['subject'] ?? json['dog_name'],
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

/// Someone who appears in the log, for the "changed by" picker. [id] is
/// null for the System pseudo-actor (entries nobody was signed in for).
class DogChangeActor {
  final String? id;
  final String name;

  const DogChangeActor({required this.id, required this.name});

  /// What the API's `?actor=` takes for this person.
  String get queryValue => id ?? 'system';

  factory DogChangeActor.fromJson(Map<String, dynamic> json) =>
      DogChangeActor(id: json['id']?.toString(), name: json['name'] ?? '');
}

const Object _unset = Object();

/// What the change-log screen is narrowed to. Immutable; [copyWith] takes
/// an explicit null to clear a field.
class DogChangeLogFilter {
  final String? dogId;
  final String? dogName;

  /// A user id, or 'system' — see [DogChangeActor.queryValue].
  final String? actorId;
  final String? actorName;

  /// One of [dogChangeActionLabels]' keys.
  final String? action;

  /// One of [dogChangeCategoryLabels]' keys.
  final String? category;
  final DateTime? from;
  final DateTime? to;

  const DogChangeLogFilter({
    this.dogId,
    this.dogName,
    this.actorId,
    this.actorName,
    this.action,
    this.category,
    this.from,
    this.to,
  });

  static const DogChangeLogFilter none = DogChangeLogFilter();

  bool get hasDog => dogId != null;
  bool get hasActor => actorId != null;
  bool get hasAction => action != null;
  bool get hasCategory => category != null;
  bool get hasDates => from != null || to != null;
  bool get isEmpty => !hasDog && !hasActor && !hasAction && !hasCategory && !hasDates;

  /// How many filters are set — the badge on the Filters button.
  int get count => [hasDog, hasActor, hasAction, hasCategory, hasDates].where((b) => b).length;

  String get actionLabel => dogChangeActionLabels[action] ?? action ?? '';
  String get categoryLabel => dogChangeCategoryLabels[category] ?? category ?? '';

  /// "01/09/26 – 15/09/26", "From 01/09/26" or "Until 15/09/26".
  String get datesLabel {
    if (from != null && to != null) return '${ukDate(from!)} – ${ukDate(to!)}';
    if (from != null) return 'From ${ukDate(from!)}';
    if (to != null) return 'Until ${ukDate(to!)}';
    return '';
  }

  DogChangeLogFilter copyWith({
    Object? dogId = _unset,
    Object? dogName = _unset,
    Object? actorId = _unset,
    Object? actorName = _unset,
    Object? action = _unset,
    Object? category = _unset,
    Object? from = _unset,
    Object? to = _unset,
  }) =>
      DogChangeLogFilter(
        dogId: identical(dogId, _unset) ? this.dogId : dogId as String?,
        dogName: identical(dogName, _unset) ? this.dogName : dogName as String?,
        actorId: identical(actorId, _unset) ? this.actorId : actorId as String?,
        actorName: identical(actorName, _unset) ? this.actorName : actorName as String?,
        action: identical(action, _unset) ? this.action : action as String?,
        category: identical(category, _unset) ? this.category : category as String?,
        from: identical(from, _unset) ? this.from : from as DateTime?,
        to: identical(to, _unset) ? this.to : to as DateTime?,
      );

  DogChangeLogFilter withoutDog() => copyWith(dogId: null, dogName: null);
  DogChangeLogFilter withoutActor() => copyWith(actorId: null, actorName: null);
  DogChangeLogFilter withoutAction() => copyWith(action: null);
  DogChangeLogFilter withoutCategory() => copyWith(category: null);
  DogChangeLogFilter withoutDates() => copyWith(from: null, to: null);
}
