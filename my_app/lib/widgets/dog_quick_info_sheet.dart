import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart';
import '../services/data_service.dart';

/// Quick-info popup for a dog, opened with a single tap from any staff dog
/// list. Shows the owner, address, pickup info and care notes at a glance,
/// with a link to the full profile.
///
/// Pass [dog] when the caller already holds a full Dog, or [assignment] when
/// opened from a daily pickup list — the full Dog is then fetched in the
/// background so care details and the profile link become available.
///
/// [show] returns the loaded Dog when the user taps "View Full Profile"
/// (the caller performs the navigation), or null if dismissed.
class DogQuickInfoSheet extends StatefulWidget {
  final Dog? dog;
  final DailyDogAssignment? assignment;

  const DogQuickInfoSheet({super.key, this.dog, this.assignment})
      : assert(dog != null || assignment != null, 'Provide a dog or an assignment');

  static Future<Dog?> show(BuildContext context, {Dog? dog, DailyDogAssignment? assignment}) {
    return showModalBottomSheet<Dog>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DogQuickInfoSheet(dog: dog, assignment: assignment),
    );
  }

  @override
  State<DogQuickInfoSheet> createState() => _DogQuickInfoSheetState();
}

class _DogQuickInfoSheetState extends State<DogQuickInfoSheet> {
  Dog? _dog;
  bool _loading = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _dog = widget.dog;
    if (_dog == null) {
      _loading = true;
      ApiDataService().getDogById(widget.assignment!.dogId.toString()).then((dog) {
        if (mounted) setState(() { _dog = dog; _loading = false; });
      }).catchError((_) {
        if (mounted) setState(() { _loading = false; _loadFailed = true; });
      });
    }
  }

  // ---- Field resolution: assignment carries the per-day values, the Dog
  // carries everything else. Prefer the assignment where both exist.

  String get _name => widget.assignment?.dogName ?? _dog!.name;
  String? get _imageUrl => widget.assignment?.dogProfileImage ?? _dog?.profileImageUrl;
  String? get _ownerName => widget.assignment?.ownerName ?? _dog?.ownerDetails?.displayName;
  String? get _phone => _firstNonEmpty(widget.assignment?.ownerPhone, _dog?.ownerDetails?.phoneNumber);
  String? get _address => _firstNonEmpty(widget.assignment?.ownerAddress, _dog?.address);
  String? get _pickupInstructions =>
      _firstNonEmpty(widget.assignment?.pickupInstructions, _dog?.ownerDetails?.pickupInstructions);

  static String? _firstNonEmpty(String? a, String? b) {
    if (a != null && a.trim().isNotEmpty) return a;
    if (b != null && b.trim().isNotEmpty) return b;
    return null;
  }

  Future<void> _openMaps(String address) async {
    final uri = Uri.parse('https://maps.apple.com/?q=${Uri.encodeComponent(address)}');
    final geoUri = Uri.parse('geo:0,0?q=${Uri.encodeComponent(address)}');
    if (await canLaunchUrl(geoUri)) {
      await launchUrl(geoUri);
    } else if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _callPhone(String phone) async {
    final uri = Uri.parse('tel:${Uri.encodeComponent(phone)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  String _formatAge(DateTime dob) {
    final now = DateTime.now();
    int years = now.year - dob.year;
    int months = now.month - dob.month;
    if (now.day < dob.day) months -= 1;
    if (months < 0) {
      years -= 1;
      months += 12;
    }
    if (years > 0 && months > 0) return '$years yr ${months}m';
    if (years > 0) return years == 1 ? '1 yr' : '$years yrs';
    return months == 1 ? '1 month' : '$months months';
  }

  /// Transport summary lines: per-day effective values when opened from a
  /// daily list, otherwise the dog's defaults.
  List<String> get _transportLines {
    final a = widget.assignment;
    final lines = <String>[];
    if (a != null) {
      if (a.effectiveOwnerBrings) {
        lines.add(a.effectiveOwnerBringsTime != null
            ? 'Owner drops off at ${formatApiTime(a.effectiveOwnerBringsTime!)}'
            : 'Owner drops off');
      }
      if (a.effectiveOwnerCollects) {
        lines.add(a.effectiveOwnerCollectsTime != null
            ? 'Owner picks up at ${formatApiTime(a.effectiveOwnerCollectsTime!)}'
            : 'Owner picks up');
      }
    } else if (_dog != null) {
      if (_dog!.ownerBringsDefault) {
        lines.add(_dog!.ownerBringsDefaultTime != null
            ? 'Owner usually drops off at ${formatApiTime(_dog!.ownerBringsDefaultTime!)}'
            : 'Owner usually drops off');
      }
      if (_dog!.ownerCollectsDefault) {
        lines.add(_dog!.ownerCollectsDefaultTime != null
            ? 'Owner usually picks up at ${formatApiTime(_dog!.ownerCollectsDefaultTime!)}'
            : 'Owner usually picks up');
      }
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context),
                    const Divider(height: 28),
                    ..._buildContactSection(context),
                    ..._buildPickupSection(context),
                    ..._buildCareSection(context),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _dog == null ? null : () => Navigator.pop(context, _dog),
                  icon: const Picon(PiconsDuotone.pawPrint, size: 20),
                  label: const Text('View Full Profile'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final chips = <Widget>[];
    if (widget.assignment?.isBoarding == true) {
      chips.add(_chip(context, PiconsDuotone.house, 'Boarding', Colors.deepPurple));
    }
    if (_dog?.sex != null) {
      chips.add(_chip(context, PiconsDuotone.heart,
          _dog!.sex == DogSex.male ? 'Male' : 'Female', AppColors.primary));
    }
    if (_dog?.dateOfBirth != null) {
      chips.add(_chip(context, PiconsDuotone.cake, _formatAge(_dog!.dateOfBirth!), AppColors.primary));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: CachedNetworkImage(
                  imageUrl: _imageUrl!,
                  width: 56, height: 56, fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    width: 56, height: 56, color: Colors.grey[200],
                    child: const Picon(PiconsDuotone.pawPrint),
                  ),
                  errorWidget: (context, url, error) =>
                      const CircleAvatar(radius: 28, child: Picon(PiconsDuotone.pawPrint)),
                ),
              )
            else
              const CircleAvatar(radius: 28, child: Picon(PiconsDuotone.pawPrint)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  if (_ownerName != null && _ownerName!.isNotEmpty)
                    Text('Owner: $_ownerName', style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: chips),
        ],
      ],
    );
  }

  Widget _chip(BuildContext context, PiconDuotoneData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Picon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6,
              )),
    );
  }

  Widget _tapRow(BuildContext context, PiconDuotoneData icon, String text, VoidCallback onTap) {
    final color = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Picon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 14, color: color, decoration: TextDecoration.underline)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(BuildContext context, PiconDuotoneData icon, String text, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Picon(icon, size: 18, color: color ?? Colors.grey[700]),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, height: 1.4, color: color))),
        ],
      ),
    );
  }

  List<Widget> _buildContactSection(BuildContext context) {
    final rows = <Widget>[];
    if (_address != null) {
      rows.add(_tapRow(context, PiconsDuotone.mapPin, _address!, () => _openMaps(_address!)));
    }
    if (_phone != null) {
      rows.add(_tapRow(context, PiconsDuotone.phone, _phone!, () => _callPhone(_phone!)));
    }
    if (rows.isEmpty) return [];
    return [
      _sectionLabel(context, 'Address & Contact'),
      ...rows,
      const SizedBox(height: 14),
    ];
  }

  List<Widget> _buildPickupSection(BuildContext context) {
    final rows = <Widget>[];
    for (final line in _transportLines) {
      rows.add(_infoRow(context, PiconsDuotone.houseLine, line, color: Colors.teal));
    }
    if (_pickupInstructions != null) {
      rows.add(_infoRow(context, PiconsDuotone.info, _pickupInstructions!));
    }
    final access = _dog?.accessInstructions;
    if (access != null && access.trim().isNotEmpty) {
      rows.add(_infoRow(context, PiconsDuotone.key, access));
    }
    final van = _dog?.vanPlacement;
    if (van != null && van.trim().isNotEmpty) {
      rows.add(_infoRow(context, PiconsDuotone.van, van));
    }
    if (rows.isEmpty) return [];
    return [
      _sectionLabel(context, 'Pickup'),
      ...rows,
      const SizedBox(height: 14),
    ];
  }

  List<Widget> _buildCareSection(BuildContext context) {
    if (_loading) {
      return [
        _sectionLabel(context, 'Care'),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('Loading details…', style: TextStyle(fontSize: 13, color: Colors.grey)),
          ]),
        ),
      ];
    }
    if (_loadFailed) {
      return [
        _sectionLabel(context, 'Care'),
        _infoRow(context, PiconsDuotone.warningCircle, "Couldn't load full details",
            color: AppColors.warning),
      ];
    }
    final rows = <Widget>[];
    final medical = _dog?.medicalNotes;
    if (medical != null && medical.trim().isNotEmpty) {
      rows.add(_infoRow(context, PiconsDuotone.firstAid, medical, color: AppColors.error));
    }
    final food = _dog?.foodInstructions;
    if (food != null && food.trim().isNotEmpty) {
      rows.add(_infoRow(context, PiconsDuotone.forkKnife, food));
    }
    final vet = _dog?.registeredVet;
    if (vet != null && vet.trim().isNotEmpty) {
      rows.add(_infoRow(context, PiconsDuotone.stethoscope, vet));
    }
    final notes = _dog?.generalNotes;
    if (notes != null && notes.trim().isNotEmpty) {
      rows.add(_infoRow(context, PiconsDuotone.notePencil, notes));
    }
    if (rows.isEmpty) return [];
    return [
      _sectionLabel(context, 'Care'),
      ...rows,
    ];
  }
}
