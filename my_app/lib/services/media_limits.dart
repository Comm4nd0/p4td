/// What the server will take for a photo or video, checked before any bytes
/// leave the phone.
///
/// The figures mirror `api/validators.py` (`MAX_IMAGE_UPLOAD_BYTES`,
/// `MAX_VIDEO_UPLOAD_BYTES`), which apply to the feed, a dog's gallery and
/// incident media alike. The server stays the authority — an app built before
/// a limit changes simply gets the server's own message — but checking here
/// saves someone on a rural connection ten minutes of uploading a video that
/// was always going to be refused.
class MediaLimits {
  MediaLimits._();

  static const int maxImageBytes = 25 * 1024 * 1024;
  static const int maxVideoBytes = 200 * 1024 * 1024;

  /// Longest clip the in-app camera records for an upload. At phone bitrates
  /// that stays well inside [maxVideoBytes]; longer than this and the upload
  /// also runs past the server's request timeout.
  static const Duration maxVideoDuration = Duration(minutes: 2);

  static int limitFor({required bool isVideo}) => isVideo ? maxVideoBytes : maxImageBytes;

  /// A sentence for the person holding the phone when a file of [bytes] is
  /// over the limit, or null when it can be sent.
  static String? problem({required int bytes, required bool isVideo, String? fileName}) {
    final limit = limitFor(isVideo: isVideo);
    if (bytes <= limit) return null;
    final what = isVideo ? 'video' : 'photo';
    final named = fileName == null || fileName.isEmpty ? 'That $what' : '"$fileName"';
    final advice = isVideo ? 'Trim it or record a shorter clip.' : 'Choose a smaller photo.';
    return '$named is ${_megabytes(bytes)} MB. '
        'The limit for a $what is ${limit ~/ (1024 * 1024)} MB. $advice';
  }

  /// Throws [MediaTooLargeException] when the file can't be sent.
  static void check({required int bytes, required bool isVideo, String? fileName}) {
    final message = problem(bytes: bytes, isVideo: isVideo, fileName: fileName);
    if (message != null) throw MediaTooLargeException(message);
  }

  // Rounded up, so a file a few bytes over never reads as exactly the limit.
  static int _megabytes(int bytes) => (bytes / (1024 * 1024)).ceil();
}

/// A photo or video over the server's size limit. [message] is written to be
/// shown as it is.
class MediaTooLargeException implements Exception {
  final String message;
  const MediaTooLargeException(this.message);

  @override
  String toString() => message;
}
