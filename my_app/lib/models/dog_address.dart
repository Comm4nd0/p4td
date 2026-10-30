/// One of a dog's alternative pickup / drop-off addresses (`dog-addresses/`).
/// The dog's own address stays the default; staff choose one of these for the
/// morning pickup, the evening drop-off or both on a given day, through the
/// transport dialog (`daily-assignments/<id>/transport/`).
class DogAddress {
  /// Alternatives per dog, on top of its own address (`DogAddress.MAX_PER_DOG`).
  static const maxPerDog = 5;

  final int id;
  final String label;
  final String address;
  final String postcode;
  final String accessInstructions;

  /// "Grandma's (12 High St)" — server-built.
  final String displayName;

  const DogAddress({
    required this.id,
    this.label = '',
    required this.address,
    this.postcode = '',
    this.accessInstructions = '',
    required this.displayName,
  });

  factory DogAddress.fromJson(Map<String, dynamic> json) => DogAddress(
        id: json['id'] as int,
        label: json['label'] as String? ?? '',
        address: json['address'] as String? ?? '',
        postcode: json['postcode'] as String? ?? '',
        accessInstructions: json['access_instructions'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
      );

  /// Parses an `alternative_addresses` list; empty for an older server.
  static List<DogAddress> listFromJson(dynamic json) => (json as List<dynamic>? ?? const [])
      .map((a) => DogAddress.fromJson(a as Map<String, dynamic>))
      .toList();
}
