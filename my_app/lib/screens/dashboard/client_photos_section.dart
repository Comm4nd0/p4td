import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../models/group_media.dart';

/// A strip of the newest feed posts tagged with the owner's dogs. Hidden
/// entirely when there are none — a "no photos yet" card would sit on every
/// new client's dashboard for weeks.
class ClientPhotosSection extends StatelessWidget {
  final List<GroupMedia> items;
  final VoidCallback? onOpenFeed;

  const ClientPhotosSection({super.key, required this.items, this.onOpenFeed});

  /// Merge the per-dog feed pages: newest first, each post once (a post
  /// tagging two of the owner's dogs comes back on both pages).
  static List<GroupMedia> merge(Iterable<List<GroupMedia>> pages, {int limit = 8}) {
    final seen = <String>{};
    final all = [
      for (final page in pages)
        for (final item in page)
          if (seen.add(item.id)) item,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all.take(limit).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Latest Photos',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (onOpenFeed != null)
              TextButton.icon(
                onPressed: onOpenFeed,
                icon: const Picon(PiconsDuotone.images, size: 16),
                label: const Text('Feed'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) => _Thumb(item: items[index], onTap: onOpenFeed),
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  final GroupMedia item;
  final VoidCallback? onTap;
  const _Thumb({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    final url = item.thumbnailUrl ?? item.fileUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: Colors.grey[200]),
                errorWidget: (_, __, ___) => Container(
                  color: Colors.grey[200],
                  child: Picon(PiconsDuotone.images, color: Colors.grey[400]),
                ),
              ),
              if (item.isVideo)
                const Center(child: Picon(PiconsDuotone.play, color: Colors.white, size: 28)),
            ],
          ),
        ),
      ),
    );
  }
}
