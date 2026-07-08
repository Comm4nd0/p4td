import 'dart:convert';

import 'auth_service.dart';
import 'http_client.dart' as http;
import 'no_connection_exception.dart';

/// Submits public enquiries from the logged-out landing page.
///
/// Deliberately not part of [DataService]: that interface attaches the auth
/// token to every call (and has interface/mock mirrors), while enquiries must
/// work with no account at all.
class EnquiryService {
  /// Returns null on success, or a user-facing error message.
  /// Throws [NoConnectionException] when the device appears to be offline.
  Future<String?> submitEnquiry({
    required String name,
    required String email,
    required String service,
    required String message,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${AuthService.baseUrl}/api/public/contact-inquiry/'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'name': name.trim(),
          'email': email.trim(),
          'service': service,
          'message': message.trim(),
        }),
      );
      if (response.statusCode == 201) return null;
      if (response.statusCode == 429) {
        return 'You have sent several messages recently. '
            'Please try again later.';
      }
      if (response.statusCode == 400) {
        // DRF returns {"field": ["message", ...]} — surface the first one.
        try {
          final data = json.decode(response.body);
          if (data is Map) {
            for (final entry in data.entries) {
              final value = entry.value;
              if (value is List && value.isNotEmpty) {
                return '${entry.key}: ${value.first}';
              }
            }
          }
        } catch (_) {}
        return 'Please check your details and try again.';
      }
      return 'Could not send your message. Please try again later.';
    } catch (e) {
      if (NoConnectionException.isNetworkError(e)) {
        throw const NoConnectionException();
      }
      rethrow;
    }
  }
}
