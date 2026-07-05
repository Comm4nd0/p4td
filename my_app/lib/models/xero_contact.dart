import 'customer_rate.dart';

/// A Xero contact summary from the reconciliation endpoints.
class XeroContact {
  final String contactId;
  final String name;
  final String email;

  XeroContact({required this.contactId, this.name = '', this.email = ''});

  factory XeroContact.fromJson(Map<String, dynamic> json) => XeroContact(
        contactId: json['contact_id'] ?? '',
        name: json['name'] ?? '',
        email: json['email'] ?? '',
      );
}

/// One customer's row from /api/xero/contact-matches/: how they line up
/// against the org's existing Xero contacts.
///
/// Statuses: 'pinned' (ContactID stored), 'email'/'name' (single confident
/// match), 'ambiguous' (several candidates), 'none'.
class XeroCustomerMatch {
  final CustomerRate customer;
  String matchStatus;
  XeroContact? matchedContact;
  final List<XeroContact> candidates;

  XeroCustomerMatch({
    required this.customer,
    required this.matchStatus,
    this.matchedContact,
    this.candidates = const [],
  });

  bool get isPinned => matchStatus == 'pinned';
  bool get needsAttention => matchStatus == 'ambiguous' || matchStatus == 'none';

  factory XeroCustomerMatch.fromJson(Map<String, dynamic> json) =>
      XeroCustomerMatch(
        customer: CustomerRate.fromJson(json),
        matchStatus: json['match_status'] ?? 'none',
        matchedContact: json['matched_contact'] == null
            ? null
            : XeroContact.fromJson(json['matched_contact']),
        candidates: (json['candidates'] as List<dynamic>?)
                ?.map((e) => XeroContact.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

/// The full /api/xero/contact-matches/ response.
class XeroContactMatches {
  final bool connected;
  final List<XeroCustomerMatch> customers;

  XeroContactMatches({required this.connected, this.customers = const []});

  factory XeroContactMatches.fromJson(Map<String, dynamic> json) =>
      XeroContactMatches(
        connected: json['connected'] ?? false,
        customers: (json['customers'] as List<dynamic>?)
                ?.map((e) => XeroCustomerMatch.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}
