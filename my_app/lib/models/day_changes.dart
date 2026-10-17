/// How one day differs from the dogs' routine — `daily-assignments/changes/`
/// (`scheduling.day_changes` on the server). Staff work from routine, and the
/// mistakes happen on the exceptions, so only the differences are listed.
class DayChange {
  static const extra = 'EXTRA';
  static const cancelled = 'CANCELLED';
  static const transport = 'TRANSPORT';
  static const boardingStart = 'BOARDING_START';
  static const boarding = 'BOARDING';
  static const boardingEnd = 'BOARDING_END';

  final int dogId;
  final String dogName;
  final String kind;
  final String detail;
  final int? usualStaffId;
  final String? usualStaffName;
  final int? staffId;
  final String? staffName;
  final String? changedByName;
  final DateTime? changedAt;

  /// On the viewer's run: the dog normally rides with them that weekday, or
  /// rides with them today.
  final bool mine;

  /// Made after the 18:00 summary for the day went out, so nobody was told.
  final bool late;

  /// The viewer has confirmed it (per person).
  final bool acknowledged;

  const DayChange({
    required this.dogId,
    required this.dogName,
    required this.kind,
    required this.detail,
    this.usualStaffId,
    this.usualStaffName,
    this.staffId,
    this.staffName,
    this.changedByName,
    this.changedAt,
    this.mine = false,
    this.late = false,
    this.acknowledged = false,
  });

  factory DayChange.fromJson(Map<String, dynamic> json) => DayChange(
        dogId: json['dog_id'] as int,
        dogName: json['dog_name'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
        usualStaffId: json['usual_staff_id'] as int?,
        usualStaffName: json['usual_staff_name'] as String?,
        staffId: json['staff_id'] as int?,
        staffName: json['staff_name'] as String?,
        changedByName: json['changed_by_name'] as String?,
        changedAt: json['changed_at'] != null
            ? DateTime.tryParse(json['changed_at'] as String)?.toLocal()
            : null,
        mine: json['mine'] as bool? ?? false,
        late: json['late'] as bool? ?? false,
        acknowledged: json['acknowledged'] as bool? ?? false,
      );

  /// A late change on the viewer's run they haven't confirmed yet — what the
  /// dashboard spotlight asks about.
  bool get needsConfirming => mine && late && !acknowledged;

  bool get isCancelled => kind == cancelled;
  bool get isExtra => kind == extra;
  bool get isBoardingKind =>
      kind == boardingStart || kind == boarding || kind == boardingEnd;

  /// A dog that won't be on [staffId]'s list today although it normally is:
  /// cancelled, or mid-stay with the boarding carer. Shown there as a greyed
  /// "not today" card, because an empty space is the easiest thing to miss.
  bool isMissingFrom(int staffId) =>
      usualStaffId == staffId &&
      staffId != this.staffId &&
      (isCancelled || kind == boarding);

  /// "Cancelled · by Sam" — the detail with who made the change.
  String get description =>
      changedByName == null || changedByName!.isEmpty
          ? detail
          : '$detail · by $changedByName';
}

class DayChanges {
  final DateTime date;
  final String weekday;
  final List<DayChange> changes;

  const DayChanges({
    required this.date,
    required this.weekday,
    required this.changes,
  });

  factory DayChanges.fromJson(Map<String, dynamic> json) => DayChanges(
        date: DateTime.parse(json['date'] as String),
        weekday: json['weekday'] as String? ?? '',
        changes: (json['changes'] as List<dynamic>? ?? [])
            .map((c) => DayChange.fromJson(c as Map<String, dynamic>))
            .toList(),
      );

  bool get isEmpty => changes.isEmpty;

  List<DayChange> get needsConfirming =>
      changes.where((c) => c.needsConfirming).toList();

  List<DayChange> missingFrom(int staffId) =>
      changes.where((c) => c.isMissingFrom(staffId)).toList();
}
