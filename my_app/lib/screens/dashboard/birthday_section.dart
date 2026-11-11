import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/dog_birthday.dart';

/// Dashboard card naming the dogs in on the day whose birthday it is, so the
/// team takes a birthday photo. Each dog shows a tick once it has been tagged
/// in a feed post that day. Draws nothing when there are none (or before the
/// list loads), and carries its own space underneath like every section.
class BirthdaySection extends StatelessWidget {
  final List<DogBirthday>? birthdays;

  /// Today, a day still to come, or one already gone — which changes the
  /// wording, and only today asks for the photo.
  final bool isToday;
  final bool isPast;
  final void Function(DogBirthday birthday)? onDogTap;

  /// Jumps to the feed to post the photo; the button hides when null.
  final VoidCallback? onOpenFeed;

  const BirthdaySection({
    super.key,
    required this.birthdays,
    required this.isToday,
    this.isPast = false,
    this.onDogTap,
    this.onOpenFeed,
  });

  static const Color _accent = Color(0xFFC2185B);

  String _title(List<DogBirthday> dogs) {
    if (dogs.length > 1) {
      return isToday
          ? '${dogs.length} birthdays today'
          : '${dogs.length} birthdays ${isPast ? 'on this day' : 'coming up'}';
    }
    final dog = dogs.first;
    if (isToday) return "It's ${dog.dogName}'s ${dog.ordinalAge} birthday today";
    return isPast
        ? '${dog.dogName} turned ${dog.age} on this day'
        : '${dog.dogName} turns ${dog.age} on this day';
  }

  String _subtitle(DogBirthday dog, {required bool single}) {
    final parts = <String>[
      if (!single) isPast ? 'Turned ${dog.age}' : 'Turns ${dog.age}',
      if (dog.boarding) 'Boarding',
      if (dog.staffMemberName.isNotEmpty) 'With ${dog.staffMemberName}',
    ];
    if (isToday) {
      parts.add(dog.photographed ? 'Photo posted' : 'Remember a birthday photo');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final dogs = birthdays;
    if (dogs == null || dogs.isEmpty) return const SizedBox.shrink();
    final needsPhoto = isToday && dogs.any((d) => !d.photographed);
    final single = dogs.length == 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _accent.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Picon(PiconsDuotone.cake, size: 22, color: _accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _title(dogs),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              for (final dog in dogs)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onTap: onDogTap == null ? null : () => onDogTap!(dog),
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: _accent.withValues(alpha: 0.12),
                    backgroundImage: dog.dogProfileImage == null
                        ? null
                        : CachedNetworkImageProvider(dog.dogProfileImage!),
                    child: dog.dogProfileImage == null
                        ? const Picon(PiconsDuotone.dog, size: 18, color: _accent)
                        : null,
                  ),
                  title: Text(dog.dogName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(_subtitle(dog, single: single)),
                  trailing: !isToday
                      ? null
                      : dog.photographed
                          ? const Picon(PiconsDuotone.checkCircle,
                              size: 22, color: AppColors.success)
                          : const Picon(PiconsDuotone.camera, size: 22, color: _accent),
                ),
              if (needsPhoto && onOpenFeed != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onOpenFeed,
                    icon: const Picon(PiconsDuotone.camera, size: 18),
                    label: const Text('Post a photo'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
