import 'dog.dart' show parseApiDate;

/// The vet's certificate behind a dog's vaccination date — a PDF or a photo.
///
/// Note what is *not* here: a file URL. Certificates are stored outside the
/// public media tree and have none; the only way to the bytes is
/// [downloadUrl], which the API serves through the owner/staff-gated download
/// view. Fetch it with the auth token (see `DataService.downloadVaccinationCertificate`),
/// never hand it to an image widget as a plain URL.
class VaccinationCertificate {
  final int id;
  final String dogId;
  final String dogName;

  /// The vaccination date this certificate evidences — whatever the date
  /// field said when it was attached. May be null for older uploads.
  final DateTime? vaccinationDate;

  /// The uploader's filename, sanitised server-side. For display only.
  final String originalFilename;

  /// What is actually stored: `application/pdf` or `image/jpeg` (every
  /// image is re-encoded to JPEG on upload, whatever came in).
  final String contentType;
  final int sizeBytes;

  /// User id of whoever attached it. Removal is theirs or staff's, so the
  /// app compares this with the signed-in user before offering "Remove".
  final int? uploadedById;
  final String? uploadedByName;
  final String downloadUrl;
  final DateTime createdAt;

  const VaccinationCertificate({
    required this.id,
    required this.dogId,
    required this.dogName,
    this.vaccinationDate,
    required this.originalFilename,
    required this.contentType,
    required this.sizeBytes,
    this.uploadedById,
    this.uploadedByName,
    required this.downloadUrl,
    required this.createdAt,
  });

  bool get isPdf => contentType == 'application/pdf';

  /// Whether the server would let [userId] remove this (staff always can).
  bool canBeRemovedBy({required int? userId, required bool isStaff}) =>
      isStaff || (userId != null && uploadedById == userId);
  bool get isImage => contentType.startsWith('image/');

  /// The extension to give a temp copy so the OS picks the right viewer.
  String get fileExtension => isPdf ? 'pdf' : 'jpg';

  /// "340 KB" / "2.1 MB".
  String get sizeLabel {
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).round()} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// What to call it in a list: the original name if there is one, else a
  /// sensible default by type.
  String get displayName =>
      originalFilename.isNotEmpty ? originalFilename : (isPdf ? 'Certificate.pdf' : 'Certificate photo');

  factory VaccinationCertificate.fromJson(Map<String, dynamic> json) {
    return VaccinationCertificate(
      id: json['id'] as int,
      dogId: json['dog'].toString(),
      dogName: json['dog_name']?.toString() ?? '',
      vaccinationDate: parseApiDate(json['vaccination_date'] as String?),
      originalFilename: json['original_filename']?.toString() ?? '',
      contentType: json['content_type']?.toString() ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      uploadedById: (json['uploaded_by'] as num?)?.toInt(),
      uploadedByName: json['uploaded_by_name'] as String?,
      downloadUrl: json['download_url']?.toString() ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
