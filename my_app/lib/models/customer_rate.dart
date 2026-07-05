/// Per-customer billing rates from /api/customer-rates/ (payment managers).
///
/// Null rates mean the standard price applies. Rates are mutable to support
/// optimistic editing in the pricing screen.
class CustomerRate {
  final int userId;
  final String username;
  final String firstName;
  final String email;
  double? daycareRate;
  double? boardingRate;

  /// 'APP' = monthly invoices auto-generated; 'MANUAL' = the business still
  /// invoices this customer by hand in Xero, so generation skips them.
  String billingMode;

  /// Pinned Xero ContactID ('' = match by email/name at push time).
  String xeroContactId;
  final List<String> dogNames;

  CustomerRate({
    required this.userId,
    required this.username,
    this.firstName = '',
    this.email = '',
    this.daycareRate,
    this.boardingRate,
    this.billingMode = 'MANUAL',
    this.xeroContactId = '',
    this.dogNames = const [],
  });

  String get displayName =>
      firstName.trim().isNotEmpty ? firstName.trim() : username;

  bool get hasCustomRate => daycareRate != null || boardingRate != null;

  bool get isAppBilled => billingMode == 'APP';

  static double? _parseRate(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  factory CustomerRate.fromJson(Map<String, dynamic> json) {
    return CustomerRate(
      userId: json['user_id'],
      username: json['username'] ?? '',
      firstName: json['first_name'] ?? '',
      email: json['email'] ?? '',
      daycareRate: _parseRate(json['daycare_rate']),
      boardingRate: _parseRate(json['boarding_rate']),
      billingMode: json['billing_mode'] ?? 'MANUAL',
      xeroContactId: json['xero_contact_id'] ?? '',
      dogNames: (json['dog_names'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

/// Standard prices from /api/billing-settings/.
class BillingSettings {
  final double dayCarePrice;
  final double boardingPricePerNight;

  /// £ off the day rate when the owner does both drop-off and pick-up.
  final double ownerTransportDiscount;

  BillingSettings({
    required this.dayCarePrice,
    required this.boardingPricePerNight,
    this.ownerTransportDiscount = 0,
  });

  factory BillingSettings.fromJson(Map<String, dynamic> json) {
    return BillingSettings(
      dayCarePrice: CustomerRate._parseRate(json['day_care_price']) ?? 0,
      boardingPricePerNight:
          CustomerRate._parseRate(json['boarding_price_per_night']) ?? 0,
      ownerTransportDiscount:
          CustomerRate._parseRate(json['owner_transport_discount']) ?? 0,
    );
  }
}
