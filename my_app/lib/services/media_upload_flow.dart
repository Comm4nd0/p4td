import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../widgets/media_tag_dialog.dart';
import '../screens/multi_photo_capture_screen.dart';
import 'data_service.dart';

/// Shared camera / gallery / multi-file upload flow for group-feed media.
///
/// This is the single entry point used by both the feed screen and the staff
/// dashboard. It owns the whole pipeline: the source bottom-sheet, video
/// extension sniffing, the [MediaTagDialog] navigation, the progress dialog
/// driving [DataService.uploadMultipleGroupMedia], and the success/failure
/// SnackBars.
///
/// Call [start] with a [BuildContext], the [DataService] and an [onComplete]
/// callback that fires once at least one file uploaded successfully (the caller
/// uses it to reload its own data — the feed or the day's assignments).
class MediaUploadFlow {
  final BuildContext context;
  final DataService dataService;

  /// Invoked after a successful upload (single or batch) so the caller can
  /// refresh whatever it shows. Not called when the user cancels or every
  /// file fails.
  final VoidCallback? onComplete;

  const MediaUploadFlow({
    required this.context,
    required this.dataService,
    this.onComplete,
  });

  static bool _isVideoName(String name) {
    final ext = name.toLowerCase();
    return ext.endsWith('.mp4') ||
        ext.endsWith('.mov') ||
        ext.endsWith('.avi') ||
        ext.endsWith('.m4v') ||
        ext.endsWith('.3gp') ||
        ext.endsWith('.webm') ||
        ext.endsWith('.mkv');
  }

  /// Present the source picker and run the chosen upload path to completion.
  Future<void> start() async {
    final picker = ImagePicker();

    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Picon(PiconsDuotone.camera),
              title: const Text('Take Photos'),
              subtitle: const Text('Capture one or more shots in a row'),
              onTap: () => Navigator.pop(context, 'camera_photo'),
            ),
            ListTile(
              leading: Picon(PiconsDuotone.videoCamera),
              title: const Text('Record Video'),
              onTap: () => Navigator.pop(context, 'camera_video'),
            ),
            const Divider(),
            ListTile(
              leading: Picon(PiconsDuotone.uploadSimple),
              title: const Text('Upload'),
              onTap: () => Navigator.pop(context, 'multiple'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    // Gallery multi-pick (images and/or videos). The size/quality caps make
    // the native picker downscale and re-encode images (videos pass through
    // untouched), so full-resolution originals — 5–15MB each, HEIC on iOS —
    // never have to be held in memory or pushed over a slow connection.
    if (choice == 'multiple') {
      final files = await picker.pickMultipleMedia(
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (files.isEmpty) return;

      final fileData = <(Uint8List, String)>[];
      final tagDialogFiles = <(Uint8List, String, bool)>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final isVideo = _isVideoName(file.name);
        fileData.add((bytes, file.name));
        tagDialogFiles.add((bytes, file.name, isVideo));
      }
      await _processAndUploadFiles(fileData, tagDialogFiles);
      return;
    }

    // Multi-shot in-app camera capture (photos only).
    if (choice == 'camera_photo') {
      if (!context.mounted) return;
      final captured = await Navigator.push<List<(Uint8List, String)>>(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const MultiPhotoCaptureScreen(),
        ),
      );
      if (captured == null || captured.isEmpty) return;
      final tagDialogFiles = captured.map((p) => (p.$1, p.$2, false)).toList();
      await _processAndUploadFiles(captured, tagDialogFiles);
      return;
    }

    // Single video capture (camera) or single gallery video — single-file flow.
    XFile? file;
    final isVideo = choice.contains('video');
    final source = choice.contains('camera') ? ImageSource.camera : ImageSource.gallery;
    if (isVideo) {
      file = await picker.pickVideo(source: source);
    } else {
      file = await picker.pickImage(source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 85);
    }
    if (file == null) return;
    final pickedFile = file;

    final bytes = await pickedFile.readAsBytes();
    if (!context.mounted) return;
    final tagResult = await Navigator.push<MediaTagResult>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => MediaTagDialog(files: [(bytes, pickedFile.name, isVideo)]),
      ),
    );
    if (tagResult == null) return; // User cancelled

    // Use the (possibly cropped) bytes returned from the tag dialog.
    final uploadBytes = tagResult.bytesByFile.isNotEmpty ? tagResult.bytesByFile[0] : bytes;

    if (!context.mounted) return;
    try {
      _showUploadingDialog();
      await dataService.uploadGroupMedia(
        fileBytes: uploadBytes,
        fileName: pickedFile.name,
        isVideo: isVideo,
        caption: tagResult.caption,
        taggedDogIds: tagResult.taggedDogIdsByFile.isNotEmpty
            ? tagResult.taggedDogIdsByFile[0]
            : null,
      );
      if (context.mounted) {
        Navigator.pop(context); // Close uploading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload successful!'), backgroundColor: AppColors.success),
        );
        onComplete?.call();
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close uploading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  /// Shared tag-prompt + batch upload pipeline used by both gallery multi-pick
  /// and in-app multi-photo capture.
  Future<void> _processAndUploadFiles(
    List<(Uint8List, String)> fileData,
    List<(Uint8List, String, bool)> tagDialogFiles,
  ) async {
    final total = fileData.length;
    if (!context.mounted) return;
    final wantTag = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$total file${total == 1 ? '' : 's'} selected'),
        content: const Text('Would you like to tag dogs and add a caption, or upload straight away?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Upload Now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tag & Caption')),
        ],
      ),
    );
    if (wantTag == null) return; // User cancelled

    List<String?>? captionsByFile;
    List<List<String>>? taggedDogIdsByFile;

    if (wantTag) {
      if (!context.mounted) return;
      final tagResult = await Navigator.push<MediaTagResult>(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => MediaTagDialog(files: tagDialogFiles),
        ),
      );
      if (tagResult == null) return; // User cancelled
      captionsByFile = tagResult.captionsByFile;
      taggedDogIdsByFile = tagResult.taggedDogIdsByFile;
      // Replace the per-file bytes with whatever the user cropped to (or
      // original bytes for items they left alone / videos).
      if (tagResult.bytesByFile.length == fileData.length) {
        for (var i = 0; i < fileData.length; i++) {
          fileData[i] = (tagResult.bytesByFile[i], fileData[i].$2);
        }
      }
    }

    await _uploadBatch(fileData, captionsByFile, taggedDogIdsByFile);
  }

  /// Upload a batch behind a progress dialog and report the outcome.
  ///
  /// On partial failure the SnackBar offers a Retry that re-runs only the
  /// failed files (with their captions/tags) through this same method.
  Future<void> _uploadBatch(
    List<(Uint8List, String)> files,
    List<String?>? captionsByFile,
    List<List<String>>? taggedDogIdsByFile,
  ) async {
    final total = files.length;
    // Whole files completed, plus byte-level progress within the current
    // file so the bar moves smoothly during large/slow uploads.
    final completed = ValueNotifier<int>(0);
    final fraction = ValueNotifier<double>(0);

    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AnimatedBuilder(
          animation: Listenable.merge([completed, fraction]),
          builder: (context, _) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Uploading '
                    '${completed.value < total ? completed.value + 1 : total}'
                    '/$total...'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: fraction.value.clamp(0.0, 1.0)),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final failures = await dataService.uploadMultipleGroupMedia(
        files: files,
        captionsByFile: captionsByFile,
        taggedDogIdsByFile: taggedDogIdsByFile,
        onProgress: (done, count) {
          completed.value = done;
          fraction.value = count > 0 ? done / count : 0;
        },
        onFileProgress: (index, sent, totalBytes) {
          if (totalBytes > 0 && total > 0) {
            fraction.value = (index + sent / totalBytes) / total;
          }
        },
      );
      if (!context.mounted) return;
      Navigator.pop(context); // Close progress dialog

      final succeeded = total - failures.length;
      if (failures.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully uploaded $total file${total == 1 ? '' : 's'}!'),
            backgroundColor: AppColors.success,
          ),
        );
      } else {
        // Carve out just the failed files (keeping their captions/tags) so
        // Retry doesn't re-upload what already made it.
        final failedFiles = [for (final f in failures) files[f.index]];
        final failedCaptions = captionsByFile == null
            ? null
            : [
                for (final f in failures)
                  f.index < captionsByFile.length ? captionsByFile[f.index] : null
              ];
        final failedTags = taggedDogIdsByFile == null
            ? null
            : [
                for (final f in failures)
                  f.index < taggedDogIdsByFile.length
                      ? taggedDogIdsByFile[f.index]
                      : <String>[]
              ];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded $succeeded/$total. '
                '${failures.length} failed — check your connection.'),
            backgroundColor: AppColors.warning,
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () {
                if (context.mounted) {
                  _uploadBatch(failedFiles, failedCaptions, failedTags);
                }
              },
            ),
          ),
        );
      }
      if (succeeded > 0) onComplete?.call();
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  void _showUploadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Uploading...'),
          ],
        ),
      ),
    );
  }
}
