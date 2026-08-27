import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/photo_tagging_status.dart';

/// Bottom sheet listing the day's dogs that haven't been tagged in any feed
/// media posted that day, grouped by the staff member they're assigned to —
/// so each staffer can see at a glance which of their dogs still need a
/// photo. Opened from the dashboard's photo-tagging progress card.
///
/// [onOpenFeed] jumps to the feed tab to post photos; the button is hidden
/// when null (e.g. viewing a past day from a context without the tab bar).
Future<void> showUntaggedDogsSheet(
  BuildContext context,
  PhotoTaggingStatus tagging, {
  VoidCallback? onOpenFeed,
}) {
  final byStaff = <String, List<UntaggedDog>>{};
  for (final d in tagging.untagged) {
    byStaff.putIfAbsent(d.staffMemberName, () => []).add(d);
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Row(children: [
                Picon(PiconsDuotone.camera,
                    size: 20,
                    color: tagging.complete
                        ? AppColors.success
                        : AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tagging.complete
                        ? 'Every dog tagged today'
                        : 'Dogs still needing a photo',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                tagging.complete
                    ? 'All ${tagging.total} dogs attending today have been '
                        'tagged in a feed photo. Nice work!'
                    : '${tagging.untagged.length} of ${tagging.total} dogs '
                        'attending today haven\'t been tagged in a feed photo '
                        'yet. Tag them when posting to the feed.',
                style: TextStyle(fontSize: 13, color: AppColors.grey600),
              ),
            ),
            if (!tagging.complete)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: byStaff.entries
                      .map((entry) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 10, 12, 2),
                                child: Text(entry.key,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold)),
                              ),
                              ...entry.value.map((dog) => ListTile(
                                    dense: true,
                                    leading: dog.dogProfileImage != null
                                        ? ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(18),
                                            child: CachedNetworkImage(
                                              imageUrl: dog.dogProfileImage!,
                                              width: 36,
                                              height: 36,
                                              fit: BoxFit.cover,
                                              errorWidget: (context, url,
                                                      error) =>
                                                  CircleAvatar(
                                                      radius: 18,
                                                      child: Picon(
                                                          PiconsDuotone
                                                              .pawPrint,
                                                          size: 18)),
                                            ),
                                          )
                                        : CircleAvatar(
                                            radius: 18,
                                            child: Picon(
                                                PiconsDuotone.pawPrint,
                                                size: 18)),
                                    title: Text(dog.dogName),
                                  )),
                            ],
                          ))
                      .toList(),
                ),
              ),
            if (onOpenFeed != null && !tagging.complete)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      onOpenFeed();
                    },
                    icon: const Picon(PiconsDuotone.camera, size: 18),
                    label: const Text('Post to the feed'),
                  ),
                ),
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}
