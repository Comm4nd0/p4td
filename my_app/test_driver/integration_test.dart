// Host-side driver for the screenshot integration test.
//
// Run via:
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart
//
// Each `binding.takeScreenshot(name)` call in the test sends PNG bytes here,
// which we write to disk. The output directory is taken from the
// SCREENSHOT_OUT environment variable so tool/screenshots.sh can namespace the
// captures per device (e.g. build/screenshots/ios-6.9). Defaults to
// `build/screenshots/raw`.

import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final outDir = Platform.environment['SCREENSHOT_OUT'] ?? 'build/screenshots/raw';

  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      final dir = Directory(outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/$name.png');
      file.writeAsBytesSync(bytes);
      stdout.writeln('📸  saved ${file.path}');
      return true;
    },
  );
}
