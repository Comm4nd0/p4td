import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'cache_service.dart';
import 'no_connection_exception.dart';

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
        if (Platform.isAndroid) return 'https://paws4thoughtdogs.com';
      } catch (e) {
        // Platform check might fail on some platforms
      }
      return 'https://paws4thoughtdogs.com';
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
      if (NoConnectionException.isNetworkError(e)) {
        throw const NoConnectionException();
      }
      return 'Error: $e';
    }
  }

  Future<void> logout() async {
    await _storage.delete(key: 'auth_token');
    // Clear local cache to prevent stale data for a different user
    try {
      final cacheService = CacheService();
      await cacheService.clearAll();
    } catch (_) {}
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
      if (NoConnectionException.isNetworkError(e)) {
        throw const NoConnectionException();
      }
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
      if (NoConnectionException.isNetworkError(e)) {
        throw const NoConnectionException();
      }
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
      if (NoConnectionException.isNetworkError(e)) {
        throw const NoConnectionException();
      }
      return 'Error: $e';
    }
  }

  /// Permanently delete the currently authenticated user's account.
  /// Requires password confirmation. Returns null on success, error message on failure.
  Future<String?> deleteAccount(String password) async {
    try {
      final token = await getToken();
      if (token == null) return 'Not authenticated';

      final response = await http.post(
        Uri.parse('$baseUrl/api/account/delete/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Token $token',
        },
        body: json.encode({'password': password}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        await logout();
        return null; // Success
      }
      final data = json.decode(response.body);
      return data['detail'] ?? 'Account deletion failed';
    } catch (e) {
      if (NoConnectionException.isNetworkError(e)) {
        throw const NoConnectionException();
      }
      return 'Error: $e';
    }
  }

  /// Change password for the currently logged-in user.
  Future<String?> changePassword(String newPassword) async {
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
        return data['detail'] ?? 'Change failed';
      }
      return 'Change failed';
    } catch (e) {
      if (NoConnectionException.isNetworkError(e)) {
        throw const NoConnectionException();
      }
      return 'Error: $e';
    }
  }
}
