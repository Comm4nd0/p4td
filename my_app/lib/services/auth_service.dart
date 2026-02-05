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
      return 'http://127.0.0.1:8000';
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
      );

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
}
