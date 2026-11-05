/// What each staff member's map pin says: the first letter of their name, or
/// the first two where two people share a letter (Ali and Ailsa become Al and
/// Ai). Emoji in a name are ignored. A name with no letters gets no entry.
Map<int, String> staffPinInitials(Map<int, String> names) {
  final letters = <int, String>{};
  names.forEach((id, name) {
    final cleaned = name.replaceAll(RegExp(r'\P{L}', unicode: true), '');
    if (cleaned.isNotEmpty) letters[id] = cleaned;
  });

  String first(String s) => String.fromCharCode(s.runes.first).toUpperCase();
  final sharing = <String, int>{};
  for (final s in letters.values) {
    sharing[first(s)] = (sharing[first(s)] ?? 0) + 1;
  }

  return letters.map((id, s) {
    if (sharing[first(s)] == 1) return MapEntry(id, first(s));
    final second = s.runes.length > 1
        ? String.fromCharCode(s.runes.elementAt(1)).toLowerCase()
        : '';
    return MapEntry(id, '${first(s)}$second');
  });
}
