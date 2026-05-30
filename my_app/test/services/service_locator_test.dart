import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/services/auth_service.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/services/theme_service.dart';

void main() {
  setUpAll(setupLocator);

  test('setupLocator is idempotent', () {
    expect(setupLocator, returnsNormally);
    expect(getIt.isRegistered<DataService>(), isTrue);
  });

  test('locator resolves the same singleton as the constructors', () {
    // Backwards-compatible singletons: legacy call sites and getIt agree.
    expect(identical(getIt<AuthService>(), AuthService()), isTrue);
    expect(identical(getIt<CacheService>(), CacheService()), isTrue);
    expect(identical(getIt<ThemeService>(), ThemeService()), isTrue);
    expect(identical(getIt<DataService>(), ApiDataService()), isTrue);
  });

  test('repeated lookups return the identical instance', () {
    expect(identical(getIt<DataService>(), getIt<DataService>()), isTrue);
  });
}
