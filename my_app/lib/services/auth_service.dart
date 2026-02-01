import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthService {
  final _storage = const FlutterSecureStorage();

  static String get baseUrl {
    if (kIsWeb) {
      return 'http://127.0.0.1:8000';
    } else {
      // Platform.isAndroid check can throw on Web, so we must be inside the else block of kIsWeb
      // However, to be safe and simple for MVP:
      try {
        if (Platform.isAndroid) return 'http://10.0.2.2:8000';
      } catch (e) {
        // Platform.isAndroid might fail on web, but kIsWeb is already checked
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
