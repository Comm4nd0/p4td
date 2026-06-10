import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import '../constants/app_colors.dart';

/// Derives a file name from the media URL, falling back to a timestamped one.
String suggestedMediaFileName(String url) {
  final last = Uri.tryParse(url)?.pathSegments.lastOrNull;
  if (last != null && last.isNotEmpty) return last;
  return 'p4td_${DateTime.now().millisecondsSinceEpoch}.jpg';
}

/// Downloads (or reuses the cached copy of) the image at [url] and saves it
/// to the device photo library, with SnackBar feedback.
Future<void> saveImageToGallery(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final hasAccess = await Gal.hasAccess();
    final granted = hasAccess ? true : await Gal.requestAccess();
    if (!granted) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Photo library permission denied. Enable it in your device settings to save photos.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    final file = await DefaultCacheManager().getSingleFile(url);
    final bytes = await file.readAsBytes();
    await Gal.putImageBytes(bytes, name: suggestedMediaFileName(url));
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Saved to your photos'),
        backgroundColor: AppColors.success,
      ),
    );
  } on GalException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Could not save: ${e.type.message}'),
        backgroundColor: AppColors.error,
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Could not save: $e'),
        backgroundColor: AppColors.error,
      ),
    );
  }
}

/// Downloads (or reuses the cached copy of) the image at [url] and opens the
/// system share sheet. The share popover is anchored to [context]'s widget
/// (required on iPad).
Future<void> shareImage(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null
      ? box.localToGlobal(Offset.zero) & box.size
      : Rect.zero;
  try {
    final file = await DefaultCacheManager().getSingleFile(url);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, name: suggestedMediaFileName(url))],
      sharePositionOrigin: origin,
    ));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Could not share: $e'),
        backgroundColor: AppColors.error,
      ),
    );
  }
}
