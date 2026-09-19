import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'app_sheets.dart';

/// Where a new certificate comes from.
enum _CertificateSource { camera, gallery, pdf }

/// Server-side cap (api/certificates.py); checked here so a too-big pick
/// fails before any upload starts.
const int maxVaccinationCertificateBytes = 10 * 1024 * 1024;

class PickedCertificate {
  final Uint8List bytes;
  final String name;
  const PickedCertificate(this.bytes, this.name);
}

/// Asks for a photo (camera or library) or a PDF of a vaccination
/// certificate and returns its bytes, or null if the user backed out or the
/// file was over the size cap (the user is told). Shared by Edit Profile,
/// which uploads on save, and the vaccinations screen, which uploads at once.
Future<PickedCertificate?> pickVaccinationCertificate(
  BuildContext context, {
  ImagePicker? picker,
}) async {
  final source = await showAppActionSheet<_CertificateSource>(
    context,
    title: 'Attach vaccination certificate',
    message: 'A photo of the card or the PDF from the vet.',
    actions: const [
      AppSheetAction(label: 'Take photo', value: _CertificateSource.camera),
      AppSheetAction(label: 'Choose photo', value: _CertificateSource.gallery),
      AppSheetAction(label: 'Choose PDF', value: _CertificateSource.pdf),
    ],
  );
  if (source == null || !context.mounted) return null;
  try {
    Uint8List? bytes;
    String? name;
    if (source == _CertificateSource.pdf) {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        withData: true,
      );
      final picked = result?.files.singleOrNull;
      if (picked == null) return null;
      bytes = picked.bytes ?? (picked.path != null ? await XFile(picked.path!).readAsBytes() : null);
      name = picked.name;
    } else {
      // Large enough that the small print on a vet's card survives; the
      // server re-encodes it anyway.
      final image = await (picker ?? ImagePicker()).pickImage(
        source: source == _CertificateSource.camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 90,
      );
      if (image == null) return null;
      bytes = await image.readAsBytes();
      name = image.name;
    }
    if (bytes == null || !context.mounted) return null;
    if (bytes.length > maxVaccinationCertificateBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That file is over 10 MB. A photo of the certificate is usually much smaller.')),
      );
      return null;
    }
    return PickedCertificate(bytes, name);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick certificate: $e')),
      );
    }
    return null;
  }
}
