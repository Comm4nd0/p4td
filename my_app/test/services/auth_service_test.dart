import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/services/auth_service.dart';

/// Sign-out, account switching and the "the server rejected this token" rule.
///
/// A phone can hold several accounts (a shared staff phone, a couple with one
/// each). These tests pin down who is left signed in after each way out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> account(int id, String token) => {
        'userId': id,
        'username': 'user$id@example.com',
        'email': 'user$id@example.com',
        'displayName': 'User $id',
        'profilePhotoUrl': null,
        'token': token,
      };

  /// Two saved accounts, the second one active.
  void twoAccounts() {
    FlutterSecureStorage.setMockInitialValues({
      'auth_token': 'token-b',
      'active_account_id': '2',
      'accounts': json.encode([account(1, 'token-a'), account(2, 'token-b')]),
    });
  }

  void oneAccount() {
    FlutterSecureStorage.setMockInitialValues({
      'auth_token': 'token-a',
      'active_account_id': '1',
      'accounts': json.encode([account(1, 'token-a')]),
    });
  }

  final auth = AuthService();

  tearDown(() => AuthService.onBeforeSignOut = null);

  group('a rejected token (HTTP 401)', () {
    test('signs out the account it belongs to and promotes the next one', () async {
      twoAccounts();

      final result = await auth.handleRejectedToken('token-b');

      expect(result.handled, isTrue);
      expect(result.next?.userId, 1);
      expect(await auth.getToken(), 'token-a');
      expect((await auth.getAccounts()).map((a) => a.userId), [1]);
    });

    test('a second 401 for the same dead token leaves the promoted account alone', () async {
      twoAccounts();

      // Several requests were in flight with token-b; each answers 401.
      final results = await Future.wait([
        auth.handleRejectedToken('token-b'),
        auth.handleRejectedToken('token-b'),
        auth.handleRejectedToken('token-b'),
      ]);

      expect(results.where((r) => r.handled), hasLength(1));
      expect(await auth.getToken(), 'token-a');
      expect((await auth.getAccounts()).map((a) => a.userId), [1]);
    });

    test('a late 401 after the last account has gone does nothing', () async {
      oneAccount();

      expect((await auth.handleRejectedToken('token-a')).handled, isTrue);
      expect(await auth.getToken(), isNull);
      expect((await auth.handleRejectedToken('token-a')).handled, isFalse);
    });

    test('a token that is not the active one is ignored', () async {
      twoAccounts();

      final result = await auth.handleRejectedToken('token-a');

      expect(result.handled, isFalse);
      expect(await auth.getToken(), 'token-b');
      expect(await auth.getAccounts(), hasLength(2));
    });

    test('an anonymous request is ignored', () async {
      twoAccounts();

      expect((await auth.handleRejectedToken(null)).handled, isFalse);
      expect((await auth.handleRejectedToken('')).handled, isFalse);
      expect(await auth.getAccounts(), hasLength(2));
    });

    test('does not try to detach the push token — the call would be refused', () async {
      oneAccount();
      var detached = 0;
      AuthService.onBeforeSignOut = () async => detached++;

      await auth.handleRejectedToken('token-a');

      expect(detached, 0);
    });
  });

  group('logout', () {
    test('drops the active account and makes the remaining one active', () async {
      twoAccounts();

      final next = await auth.logout();

      expect(next?.userId, 1);
      expect(await auth.getToken(), 'token-a');
      expect(await auth.getActiveAccountId(), 1);
    });

    test('the last account out leaves nothing behind', () async {
      oneAccount();

      expect(await auth.logout(), isNull);

      expect(await auth.getToken(), isNull);
      expect(await auth.getAccounts(), isEmpty);
      expect(await auth.getActiveAccountId(), isNull);
    });

    test('detaches the push token while the outgoing token is still active', () async {
      twoAccounts();
      String? tokenAtDetach;
      AuthService.onBeforeSignOut = () async => tokenAtDetach = await auth.getToken();

      await auth.logout();

      expect(tokenAtDetach, 'token-b');
    });

    test('still signs out when detaching the push token fails', () async {
      oneAccount();
      AuthService.onBeforeSignOut = () async => throw Exception('no signal');

      expect(await auth.logout(), isNull);
      expect(await auth.getToken(), isNull);
    });

    test('does not wait for ever on a push detach that never returns', () async {
      oneAccount();
      AuthService.onBeforeSignOut = () => Completer<void>().future;

      final done = auth.logout();

      await expectLater(done.timeout(const Duration(seconds: 10)), completion(isNull));
      expect(await auth.getToken(), isNull);
    });

    test('two sign-outs at once remove one account each, never the same one twice', () async {
      twoAccounts();

      await Future.wait([auth.logout(), auth.logout()]);

      expect(await auth.getToken(), isNull);
      expect(await auth.getAccounts(), isEmpty);
    });
  });

  group('logoutAll', () {
    test('signs every account out and detaches the push token once', () async {
      twoAccounts();
      var detached = 0;
      AuthService.onBeforeSignOut = () async => detached++;

      await auth.logoutAll();

      expect(detached, 1);
      expect(await auth.getToken(), isNull);
      expect(await auth.getAccounts(), isEmpty);
    });

    test('with nobody signed in there is nothing to detach', () async {
      FlutterSecureStorage.setMockInitialValues({});
      var detached = 0;
      AuthService.onBeforeSignOut = () async => detached++;

      await auth.logoutAll();

      expect(detached, 0);
    });
  });

  group('switchAccount', () {
    test('makes the chosen account active and keeps both saved', () async {
      twoAccounts();

      final now = await auth.switchAccount(1);

      expect(now?.userId, 1);
      expect(await auth.getToken(), 'token-a');
      expect(await auth.getActiveAccountId(), 1);
      expect(await auth.getAccounts(), hasLength(2));
    });

    test('an unknown account changes nothing', () async {
      twoAccounts();

      expect(await auth.switchAccount(99), isNull);
      expect(await auth.getToken(), 'token-b');
    });

    test('a 401 for the account just switched away from is ignored', () async {
      twoAccounts();

      await auth.switchAccount(1);
      final result = await auth.handleRejectedToken('token-b');

      expect(result.handled, isFalse);
      expect(await auth.getToken(), 'token-a');
      expect(await auth.getAccounts(), hasLength(2));
    });
  });
}
