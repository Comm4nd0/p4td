import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/services/media_limits.dart';

/// The size limits mirror `api/validators.py`; if the server's change, change
/// both — these numbers are the contract.
void main() {
  const mb = 1024 * 1024;

  test('the limits are the server\'s: 25 MB a photo, 200 MB a video', () {
    expect(MediaLimits.maxImageBytes, 25 * mb);
    expect(MediaLimits.maxVideoBytes, 200 * mb);
  });

  test('a file at the limit is fine, one byte over is not', () {
    expect(MediaLimits.problem(bytes: 25 * mb, isVideo: false), isNull);
    expect(MediaLimits.problem(bytes: 25 * mb + 1, isVideo: false), isNotNull);
    expect(MediaLimits.problem(bytes: 200 * mb, isVideo: true), isNull);
    expect(MediaLimits.problem(bytes: 200 * mb + 1, isVideo: true), isNotNull);
  });

  test('a video may be bigger than a photo', () {
    expect(MediaLimits.problem(bytes: 100 * mb, isVideo: true), isNull);
    expect(MediaLimits.problem(bytes: 100 * mb, isVideo: false), isNotNull);
  });

  test('the message names the file, its size, the limit and what to do', () {
    final message =
        MediaLimits.problem(bytes: 312 * mb, isVideo: true, fileName: 'park.mov')!;

    expect(message, contains('"park.mov"'));
    expect(message, contains('312 MB'));
    expect(message, contains('200 MB'));
    expect(message, contains('shorter clip'));
  });

  test('a file just over never reads as exactly the limit', () {
    expect(MediaLimits.problem(bytes: 200 * mb + 1, isVideo: true), contains('201 MB'));
  });

  test('check throws the message as it should be shown', () {
    expect(
      () => MediaLimits.check(bytes: 26 * mb, isVideo: false),
      throwsA(isA<MediaTooLargeException>().having(
          (e) => e.toString(), 'toString', startsWith('That photo is 26 MB.'))),
    );
    expect(() => MediaLimits.check(bytes: 1, isVideo: false), returnsNormally);
  });
}
