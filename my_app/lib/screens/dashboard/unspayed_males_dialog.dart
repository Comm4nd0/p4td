import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../services/data_service.dart';
import '../../widgets/dog_quick_info_sheet.dart';
import '../dog_home_screen.dart';

/// Read-only dialog listing male dogs over a year old that aren't yet marked
/// neutered, prompting staff to confirm with the owner. Tapping a dog opens
/// the same quick-info sheet used on the staff dog lists, with follow-on
/// navigation to the full profile.
///
/// Extracted from [UnifiedDashboardScreen] (audit F14).
Future<void> showUnspayedMalesDialog(
  BuildContext context,
  List<UnspayedMaleSummary> unspayedMales,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Neutered status to confirm'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'These dogs are over 1 year old and not yet marked as neutered. '
            'Please ask the owner whether their dog has been neutered yet.',
          ),
          const SizedBox(height: 12),
          ...unspayedMales.map((d) => InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openQuickInfo(ctx, d),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      _dogAvatar(d.imageUrl),
                      const SizedBox(width: 10),
                      Expanded(child: Text(d.name)),
                    ],
                  ),
                ),
              )),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Widget _dogAvatar(String? imageUrl) {
  if (imageUrl == null || imageUrl.isEmpty) {
    return const CircleAvatar(radius: 18, child: Picon(PiconsDuotone.dog, size: 18));
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: CachedNetworkImage(
      imageUrl: imageUrl,
      width: 36,
      height: 36,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(
        width: 36,
        height: 36,
        color: Colors.grey[200],
        child: const Picon(PiconsDuotone.dog, size: 18),
      ),
      errorWidget: (context, url, error) =>
          const CircleAvatar(radius: 18, child: Picon(PiconsDuotone.dog, size: 18)),
    ),
  );
}

Future<void> _openQuickInfo(BuildContext context, UnspayedMaleSummary summary) async {
  final dog = await DogQuickInfoSheet.show(
    context,
    dogId: summary.id,
    dogName: summary.name,
    dogImageUrl: summary.imageUrl,
  );
  if (dog == null || !context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DogHomeScreen(dog: dog, isStaff: true)),
  );
}
