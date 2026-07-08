/// Public business contact details shown on the logged-out landing page.
/// Values mirror the website (website/context_processors.py and contact.html)
/// — update both together if any of these change.
class BusinessInfo {
  BusinessInfo._();

  static const String phone = '07966184948';

  /// Human-friendly spacing for display; [phone] is what gets dialled.
  static const String phoneDisplay = '07966 184948';

  static const String hours = 'Mon–Fri 8:00 – 17:00';

  static const String serviceArea = 'Berkshire & Buckinghamshire, UK';

  static const String serviceAreaDetail =
      'Based near the Berkshire / Buckinghamshire border — '
      'exact address provided on booking';

  static const String facebookUrl = 'https://www.facebook.com/paws4thoughtdogs/';
}
