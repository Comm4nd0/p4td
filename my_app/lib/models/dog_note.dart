enum DogNoteType {
  compatibility,
  behavioral,
  grouping;

  String get apiValue {
    switch (this) {
      case DogNoteType.compatibility:
        return 'COMPATIBILITY';
      case DogNoteType.behavioral:
        return 'BEHAVIORAL';
      case DogNoteType.grouping:
        return 'GROUPING';
    }
  }

  String get displayName {
    switch (this) {
      case DogNoteType.compatibility:
        return 'Compatibility';
      case DogNoteType.behavioral:
        return 'Behavioral';
      case DogNoteType.grouping:
        return 'Grouping';
    }
  }

  static DogNoteType fromApi(String value) {
    switch (value) {
      case 'BEHAVIORAL':
        return DogNoteType.behavioral;
      case 'GROUPING':
        return DogNoteType.grouping;
      default:
        return DogNoteType.compatibility;
    }
  }
}

class DogNote {
  final int id;
  final int dogId;
  final String dogName;
  final int? relatedDogId;
  final String? relatedDogName;

  /// The rest of a group note's dogs, beyond [dogId] and [relatedDogId].
  /// A negative group note means the dogs are fine in any smaller mix and
  /// must not all be in together. Empty for an ordinary pair note.
  final List<int> extraDogIds;
  final List<String> extraDogNames;
  final DogNoteType noteType;
  final String text;
  final bool isPositive;
  final String? createdByName;
  final DateTime createdAt;

  DogNote({
    required this.id,
    required this.dogId,
    required this.dogName,
    this.relatedDogId,
    this.relatedDogName,
    this.extraDogIds = const [],
    this.extraDogNames = const [],
    required this.noteType,
    required this.text,
    required this.isPositive,
    this.createdByName,
    required this.createdAt,
  });

  bool get isGroup => extraDogIds.isNotEmpty;

  /// Names of every dog on the note except [dogId], in the note's order —
  /// what a profile shows as "With …".
  List<String> otherDogNames(int currentDogId) {
    final names = <String>[];
    if (dogId != currentDogId) names.add(dogName);
    if (relatedDogId != null && relatedDogId != currentDogId && relatedDogName != null) {
      names.add(relatedDogName!);
    }
    for (var i = 0; i < extraDogIds.length && i < extraDogNames.length; i++) {
      if (extraDogIds[i] != currentDogId) names.add(extraDogNames[i]);
    }
    return names;
  }

  factory DogNote.fromJson(Map<String, dynamic> json) {
    return DogNote(
      id: json['id'],
      dogId: json['dog'] is int ? json['dog'] : int.parse(json['dog'].toString()),
      dogName: json['dog_name'] ?? '',
      relatedDogId: json['related_dog'] != null
          ? (json['related_dog'] is int ? json['related_dog'] : int.parse(json['related_dog'].toString()))
          : null,
      relatedDogName: json['related_dog_name'],
      extraDogIds: (json['extra_dogs'] as List<dynamic>? ?? [])
          .map((e) => e is int ? e : int.parse(e.toString()))
          .toList(),
      extraDogNames: (json['extra_dog_names'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      noteType: DogNoteType.fromApi(json['note_type'] ?? 'COMPATIBILITY'),
      text: json['text'] ?? '',
      isPositive: json['is_positive'] ?? true,
      createdByName: json['created_by_name'],
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
