import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthService {
  final _storage = const FlutterSecureStorage();

  // Production URL can be set at compile time:
  // flutter build apk --dart-define=API_URL=https://your-api.com
  static const String _prodUrl = String.fromEnvironment('API_URL');
  
  static String get baseUrl {
    // Use production URL if set via --dart-define
    if (_prodUrl.isNotEmpty) {
      return _prodUrl;
    }
    
    // Development fallbacks
    if (kIsWeb) {
      return 'http://127.0.0.1:8000';
    } else {
      try {
        if (Platform.isAndroid) return 'http://46.137.83.83:8000';
      } catch (e) {
        // Platform check might fail on some platforms
      }
      return 'http://46.137.83.83:8000';
    }
  }

  Future<String?> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/token/login/'),
        body: {
          'username': username,
          'password': password,
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final token = data['auth_token'];
        await _storage.write(key: 'auth_token', value: token);
        return null; // Success
      } else {
        try {
          final errorData = json.decode(response.body);
          if (errorData is Map) {
            if (errorData.containsKey('non_field_errors')) {
              return (errorData['non_field_errors'] as List).first.toString();
            }
            // Return first value of any other error
            return errorData.values.first.toString();
          }
        } catch (_) {
          // Fallback if parsing fails
        }
        return 'Login failed: ${response.statusCode}';
      }
    } catch (e) {
      return 'Error: $e';
    }
  }

  Future<void> logout() async {
    await _storage.delete(key: 'auth_token');
  }

  Future<String?> getToken() async {
    return await _storage.read(key: 'auth_token');
  }

  /// Step 1: Request a password reset OTP to be sent to the given email.
  Future<String?> requestPasswordReset(String email) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/password/reset/request/'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return null; // Success
      }
      final data = json.decode(response.body);
      return data['detail'] ?? 'Request failed';
    } catch (e) {
      return 'Error: $e';
    }
  }

  /// Step 2: Verify the OTP and get a reset token.
  Future<Map<String, dynamic>> verifyOTP(String email, String otp) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/password/reset/verify/'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'otp': otp}),
      ).timeout(const Duration(seconds: 10));

      final data = json.decode(response.body);
      if (response.statusCode == 200) {
        return {'success': true, 'reset_token': data['reset_token']};
      }
      return {'success': false, 'error': data['detail'] ?? 'Verification failed'};
    } catch (e) {
      return {'success': false, 'error': 'Error: $e'};
    }
  }

  /// Step 3: Set the new password using the reset token.
  Future<String?> resetPassword(String resetToken, String newPassword) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/password/reset/confirm/'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'reset_token': resetToken,
          'new_password': newPassword,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return null; // Success
      }
      final data = json.decode(response.body);
      if (data is Map) {
        if (data.containsKey('new_password')) {
          final errors = data['new_password'];
          if (errors is List) return errors.join('\n');
          return errors.toString();
        }
        return data['detail'] ?? 'Reset failed';
      }
      return 'Reset failed';
    } catch (e) {
      return 'Error: $e';
    }
  }

  /// Change password for the currently logged-in user.
  Future<String?> changePassword(String currentPassword, String newPassword) async {
    try {
      final token = await getToken();
      if (token == null) return 'Not authenticated';

      final response = await http.post(
        Uri.parse('$baseUrl/api/password/change/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Token $token',
        },
        body: json.encode({
          'current_password': currentPassword,
          'new_password': newPassword,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return null; // Success
      }
      final data = json.decode(response.body);
      if (data is Map) {
        if (data.containsKey('current_password')) {
          final errors = data['current_password'];
          if (errors is List) return errors.join('\n');
          return errors.toString();
        }
        if (data.containsKey('new_password')) {
          final errors = data['new_password'];
          if (errors is List) return errors.join('\n');
          return errors.toString();
        }
        return data['detail'] ?? 'Change failed';
      }
      return 'Change failed';
    } catch (e) {
      return 'Error: $e';
    }
  }
}
