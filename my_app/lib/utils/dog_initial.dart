/// What a dog's map pin says: the first letter of its name, in capitals. Emoji
/// and punctuation are skipped. A name with no letters gives null.
String? dogPinInitial(String name) {
  final letter = RegExp(r'\p{L}', unicode: true).firstMatch(name)?.group(0);
  return letter?.toUpperCase();
}
