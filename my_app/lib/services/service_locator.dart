import 'package:get_it/get_it.dart';

import 'auth_service.dart';
import 'cache_service.dart';
import 'data_service.dart';
import 'notification_service.dart';
import 'theme_service.dart';

/// Global service locator.
///
/// Prefer resolving services through `getIt<T>()` in new code, e.g.
/// `final dataService = getIt<DataService>();`. The concrete service classes
/// are also backwards-compatible singletons, so legacy `ApiDataService()` /
/// `AuthService()` call sites resolve to the very same instances registered
/// here — there is only ever one of each.
final GetIt getIt = GetIt.instance;

/// Registers all app services. Call once from `main()` before `runApp()`.
void setupLocator() {
  if (getIt.isRegistered<DataService>()) return; // idempotent (e.g. hot restart)

  getIt.registerLazySingleton<CacheService>(() => CacheService());
  getIt.registerLazySingleton<AuthService>(() => AuthService());
  getIt.registerLazySingleton<DataService>(() => ApiDataService());
  getIt.registerLazySingleton<ThemeService>(() => ThemeService());
  getIt.registerLazySingleton<NotificationService>(() => NotificationService());
}
