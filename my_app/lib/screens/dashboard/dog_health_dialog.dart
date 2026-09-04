import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../services/data_service.dart';
import '../../widgets/dog_quick_info_sheet.dart';
import '../dog_home_screen.dart';

/// Read-only dialog behind the dashboard's "Dog health to confirm" row: the
/// dogs whose owners need a word, grouped by why.
///
/// * Neutered status to confirm — male dogs over a year old not yet marked
///   neutered.
/// * Vaccinations overdue — dogs whose last vaccination date is more than a
///   year old.
///
/// Tapping a dog opens the same quick-info sheet used on the staff dog lists,
/// with follow-on navigation to the full profile (where the date and the
/// certificate can be updated). A dog can appear in both lists.
Future<void> showDogHealthDialog(BuildContext context, DogHealthFlags flags) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Dog health to confirm'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (flags.unspayedMales.isNotEmpty)
              _HealthGroup(
                icon: PiconsDuotone.heart,
                title: 'Neutered status to confirm',
                explanation: 'Over 1 year old and not yet marked as neutered. '
                    'Please ask the owner whether their dog has been neutered yet.',
                dogs: flags.unspayedMales,
              ),
            if (flags.unspayedMales.isNotEmpty && flags.vaccinationsOverdue.isNotEmpty)
              const SizedBox(height: 16),
            if (flags.vaccinationsOverdue.isNotEmpty)
              _HealthGroup(
                icon: PiconsDuotone.syringe,
                title: 'Vaccinations overdue',
                explanation: 'Last vaccination date is more than a year ago. '
                    'Please ask the owner for the booster date and the new certificate.',
                dogs: flags.vaccinationsOverdue,
                detail: (d) => d.lastVaccinationDate == null
                    ? null
                    : 'Last vaccinated ${_ukDate(d.lastVaccinationDate!)}',
              ),
            if (flags.unspayedMales.isEmpty && flags.vaccinationsOverdue.isEmpty)
              const Text('Nothing to confirm right now.'),
          ],
        ),
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

String _ukDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

class _HealthGroup extends StatelessWidget {
  final PiconDuotoneData icon;
  final String title;
  final String explanation;
  final List<FlaggedDogSummary> dogs;
  final String? Function(FlaggedDogSummary)? detail;

  const _HealthGroup({
    required this.icon,
    required this.title,
    required this.explanation,
    required this.dogs,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Picon(icon, size: 16, color: AppColors.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text('$title (${dogs.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.error)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(explanation, style: TextStyle(fontSize: 13, color: Colors.grey[700])),
        const SizedBox(height: 8),
        ...dogs.map((d) {
          final line = detail?.call(d);
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _openQuickInfo(context, d),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  _dogAvatar(d.imageUrl),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name),
                        if (line != null)
                          Text(line, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
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

Future<void> _openQuickInfo(BuildContext context, FlaggedDogSummary summary) async {
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
