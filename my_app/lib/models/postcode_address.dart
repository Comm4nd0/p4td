/// A single address returned by the backend postcode-lookup endpoint
/// (`GET /api/postcode/lookup/`). Used to autofill a dog's registered vet.
class PostcodeAddress {
  /// Full single-line address including the postcode, e.g.
  /// "1 High Street, Reading, Berkshire, RG1 1AA".
  final String formatted;

  /// Individual address lines (without the postcode).
  final List<String> lines;

  /// The normalised postcode, e.g. "RG1 1AA".
  final String postcode;

  PostcodeAddress({
    required this.formatted,
    required this.lines,
    required this.postcode,
  });

  factory PostcodeAddress.fromJson(Map<String, dynamic> json) {
    return PostcodeAddress(
      formatted: (json['formatted'] ?? '').toString(),
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      postcode: (json['postcode'] ?? '').toString(),
    );
  }
}
