import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'cache_service.dart';
import 'no_connection_exception.dart';

/// A saved account on this device. The token is the long-lived auth token
/// returned by Djoser's `auth/token/login/` endpoint.
class Account {
  final int userId;
  final String username;
  final String email;
  final String? displayName;
  final String? profilePhotoUrl;
  final String token;

  const Account({
    required this.userId,
    required this.username,
    required this.email,
    required this.token,
    this.displayName,
    this.profilePhotoUrl,
  });

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'email': email,
        'displayName': displayName,
        'profilePhotoUrl': profilePhotoUrl,
        'token': token,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        userId: json['userId'] as int,
        username: json['username'] as String,
        email: json['email'] as String,
        displayName: json['displayName'] as String?,
        profilePhotoUrl: json['profilePhotoUrl'] as String?,
        token: json['token'] as String,
      );

  Account copyWith({
    String? username,
    String? email,
    String? displayName,
    String? profilePhotoUrl,
    String? token,
  }) =>
      Account(
        userId: userId,
        username: username ?? this.username,
        email: email ?? this.email,
        displayName: displayName ?? this.displayName,
        profilePhotoUrl: profilePhotoUrl ?? this.profilePhotoUrl,
        token: token ?? this.token,
      );
}

class AuthService {
  final _storage = const FlutterSecureStorage();

  static const _kActiveToken = 'auth_token';
  static const _kAccounts = 'accounts';
  static const _kActiveAccountId = 'active_account_id';

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
        await _storage.write(key: _kActiveToken, value: token);
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

  /// Signs out the *active* account. If there are other saved accounts, the
  /// most recently registered one becomes active and its token is loaded.
  /// Otherwise all session state is cleared (token + cache).
  ///
  /// Returns the [Account] that is now active, or null if the user is fully
  /// signed out.
  Future<Account?> logout() async {
    final accounts = await getAccounts();
    final activeId = await getActiveAccountId();
    final remaining = accounts.where((a) => a.userId != activeId).toList();

    // Always wipe the per-user cache — the next signed-in account must not
    // see stale data from the previous one.
    try {
      await CacheService().clearAll();
    } catch (_) {}

    if (remaining.isEmpty) {
      await _storage.delete(key: _kActiveToken);
      await _storage.delete(key: _kAccounts);
      await _storage.delete(key: _kActiveAccountId);
      return null;
    }

    await _writeAccounts(remaining);
    final next = remaining.last;
    await _storage.write(key: _kActiveToken, value: next.token);
    await _storage.write(key: _kActiveAccountId, value: next.userId.toString());
    return next;
  }

  /// Signs out of every account on this device and clears the cache.
  Future<void> logoutAll() async {
    await _storage.delete(key: _kActiveToken);
    await _storage.delete(key: _kAccounts);
    await _storage.delete(key: _kActiveAccountId);
    try {
      await CacheService().clearAll();
    } catch (_) {}
  }

  Future<String?> getToken() async {
    return await _storage.read(key: _kActiveToken);
  }

  /// All accounts saved on this device.
  Future<List<Account>> getAccounts() async {
    final raw = await _storage.read(key: _kAccounts);
    if (raw == null || raw.isEmpty) return <Account>[];
    try {
      final list = json.decode(raw) as List;
      return list
          .map((e) => Account.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return <Account>[];
    }
  }

  Future<int?> getActiveAccountId() async {
    final raw = await _storage.read(key: _kActiveAccountId);
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  Future<void> _writeAccounts(List<Account> accounts) async {
    final payload = json.encode(accounts.map((a) => a.toJson()).toList());
    await _storage.write(key: _kAccounts, value: payload);
  }

  /// Records the currently-active session as an [Account] in the device's
  /// account list (or refreshes the existing record). Call this whenever the
  /// active user's profile is loaded so the switcher stays in sync.
  Future<void> upsertActiveAccount({
    required int userId,
    required String username,
    required String email,
    String? displayName,
    String? profilePhotoUrl,
  }) async {
    final token = await getToken();
    if (token == null) return; // Nothing to record.

    final previousActiveId = await getActiveAccountId();
    final accounts = await getAccounts();
    final idx = accounts.indexWhere((a) => a.userId == userId);
    final updated = Account(
      userId: userId,
      username: username,
      email: email,
      displayName: displayName,
      profilePhotoUrl: profilePhotoUrl,
      token: token,
    );
    if (idx >= 0) {
      accounts[idx] = updated;
    } else {
      accounts.add(updated);
    }
    await _writeAccounts(accounts);
    await _storage.write(key: _kActiveAccountId, value: userId.toString());

    // If the active user changed (e.g. an "add another account" flow that
    // logged in as a different user), wipe the shared cache so the new
    // session doesn't see the previous user's data.
    if (previousActiveId != null && previousActiveId != userId) {
      try {
        await CacheService().clearAll();
      } catch (_) {}
    }
  }

  /// Switch the active session to [userId]. The caller is responsible for
  /// routing the UI back to the home screen afterwards — the cache is cleared
  /// here so the next data fetch comes from the network.
  ///
  /// Returns the now-active [Account], or null if no matching account exists.
  Future<Account?> switchAccount(int userId) async {
    final accounts = await getAccounts();
    final target = accounts.where((a) => a.userId == userId).firstOrNull;
    if (target == null) return null;

    await _storage.write(key: _kActiveToken, value: target.token);
    await _storage.write(key: _kActiveAccountId, value: target.userId.toString());
    try {
      await CacheService().clearAll();
    } catch (_) {}
    return target;
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
