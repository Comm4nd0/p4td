import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';

/// Bottom sheet that searches a list of dogs by name or owner and returns
/// the tapped one. Show it with [showDogPicker].
Future<Dog?> showDogPicker(
  BuildContext context, {
  required List<Dog> dogs,
  String title = 'Choose a dog',
  String? subtitle,
}) {
  return showModalBottomSheet<Dog>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DogPickerSheet(dogs: dogs, title: title, subtitle: subtitle),
  );
}

class DogPickerSheet extends StatefulWidget {
  final List<Dog> dogs;
  final String title;
  final String? subtitle;

  const DogPickerSheet({
    super.key,
    required this.dogs,
    this.title = 'Choose a dog',
    this.subtitle,
  });

  @override
  State<DogPickerSheet> createState() => _DogPickerSheetState();
}

class _DogPickerSheetState extends State<DogPickerSheet> {
  String _search = '';

  static String _ownerLabel(Dog dog) {
    final owner = dog.ownerDetails;
    if (owner == null) return 'No client on the app';
    return owner.displayName;
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.toLowerCase();
    final visible = widget.dogs
        .where((d) =>
            query.isEmpty ||
            d.name.toLowerCase().contains(query) ||
            _ownerLabel(d).toLowerCase().contains(query))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  children: [
                    Text(widget.title,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.subtitle!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search dogs or owners',
                        prefixIcon: const Picon(PiconsDuotone.magnifyingGlass, size: 20),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onChanged: (value) => setState(() => _search = value),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text('No dogs found',
                            style: TextStyle(color: Colors.grey[600])),
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final dog = visible[index];
                          // Several dogs share a name — the photo (and the
                          // owner line) is how staff tell them apart.
                          return ListTile(
                            leading: DogPickerAvatar(imageUrl: dog.profileImageUrl),
                            title: Text(dog.name),
                            subtitle: Text(_ownerLabel(dog),
                                style: const TextStyle(fontSize: 12)),
                            onTap: () => Navigator.pop(context, dog),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dog's photo as a small circle, with a paw print when there isn't one.
class DogPickerAvatar extends StatelessWidget {
  final String? imageUrl;
  final double radius;

  const DogPickerAvatar({super.key, this.imageUrl, this.radius = 22});

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.grey200,
      child: Picon(PiconsDuotone.pawPrint, size: radius, color: Colors.grey[700]),
    );
    if (imageUrl == null) return fallback;
    final size = radius * 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(width: size, height: size, color: AppColors.grey200),
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}
