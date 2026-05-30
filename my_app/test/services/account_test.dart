import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/services/auth_service.dart';

void main() {
  group('Account', () {
    const account = Account(
      userId: 42,
      username: 'marco',
      email: 'marco@example.com',
      token: 'abc123',
      displayName: 'Marco B',
      profilePhotoUrl: 'https://example.com/p.jpg',
    );

    test('toJson / fromJson round-trips', () {
      final restored = Account.fromJson(account.toJson());
      expect(restored.userId, account.userId);
      expect(restored.username, account.username);
      expect(restored.email, account.email);
      expect(restored.token, account.token);
      expect(restored.displayName, account.displayName);
      expect(restored.profilePhotoUrl, account.profilePhotoUrl);
    });

    test('fromJson tolerates missing optional fields', () {
      final restored = Account.fromJson({
        'userId': 1,
        'username': 'u',
        'email': 'u@x.com',
        'token': 't',
      });
      expect(restored.displayName, isNull);
      expect(restored.profilePhotoUrl, isNull);
    });

    test('copyWith preserves userId and overrides selected fields', () {
      final updated = account.copyWith(token: 'new', displayName: 'New Name');
      expect(updated.userId, 42); // copyWith does not expose userId
      expect(updated.token, 'new');
      expect(updated.displayName, 'New Name');
      expect(updated.email, account.email);
    });
  });
}
