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
  /// Legacy flat daycare rate (older servers); invoicing uses the tiers.
  final double dayCarePrice;

  /// Daycare per-day tiers by how many days a week the dog is booked in.
  /// The tier follows the booking, not attendance: a one-day-a-week dog
  /// that adds a day pays [dayCarePrice1Day] for both.
  final double dayCarePrice1Day;
  final double dayCarePrice2To4Days;
  final double dayCarePrice5Days;
  final double boardingPricePerNight;

  /// £ off the day rate when the owner does both drop-off and pick-up.
  final double ownerTransportDiscount;

  BillingSettings({
    required this.dayCarePrice,
    double? dayCarePrice1Day,
    double? dayCarePrice2To4Days,
    double? dayCarePrice5Days,
    required this.boardingPricePerNight,
    this.ownerTransportDiscount = 0,
  })  : dayCarePrice1Day = dayCarePrice1Day ?? dayCarePrice,
        dayCarePrice2To4Days = dayCarePrice2To4Days ?? dayCarePrice,
        dayCarePrice5Days = dayCarePrice5Days ?? dayCarePrice;

  factory BillingSettings.fromJson(Map<String, dynamic> json) {
    return BillingSettings(
      dayCarePrice: CustomerRate._parseRate(json['day_care_price']) ?? 0,
      dayCarePrice1Day: CustomerRate._parseRate(json['day_care_price_1_day']),
      dayCarePrice2To4Days: CustomerRate._parseRate(json['day_care_price_2_to_4_days']),
      dayCarePrice5Days: CustomerRate._parseRate(json['day_care_price_5_days']),
      boardingPricePerNight:
          CustomerRate._parseRate(json['boarding_price_per_night']) ?? 0,
      ownerTransportDiscount:
          CustomerRate._parseRate(json['owner_transport_discount']) ?? 0,
    );
  }
}
