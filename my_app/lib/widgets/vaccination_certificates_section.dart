import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/vaccination_certificate.dart';
import '../screens/vaccination_certificate_screen.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import 'grouped_section.dart';
import 'vaccination_certificate_picker.dart';
import 'vaccination_certificate_tile.dart';

/// A dog's vaccination certificates with an Attach button that uploads
/// straight away. Owners, co-owners and staff can all add one; only the
/// uploader or staff can remove one. Sits at the top of the vaccinations
/// screen so a client sent there by a reminder can act on it in place.
class VaccinationCertificatesSection extends StatefulWidget {
  final String dogId;
  final bool isStaff;

  const VaccinationCertificatesSection({super.key, required this.dogId, required this.isStaff});

  @override
  State<VaccinationCertificatesSection> createState() => _VaccinationCertificatesSectionState();
}

class _VaccinationCertificatesSectionState extends State<VaccinationCertificatesSection> {
  final DataService _dataService = getIt<DataService>();
  List<VaccinationCertificate> _certificates = [];
  bool _loading = true;
  bool _uploading = false;
  int? _myUserId;

  @override
  void initState() {
    super.initState();
    _load();
    _dataService.getProfile().then((profile) {
      if (mounted) setState(() => _myUserId = profile.userId);
    }).catchError((_) {});
  }

  Future<void> _load() async {
    try {
      final certificates = await _dataService.getVaccinationCertificates(widget.dogId);
      if (mounted) {
        setState(() {
          _certificates = certificates;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _attach() async {
    final picked = await pickVaccinationCertificate(context);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      await _dataService.uploadVaccinationCertificate(
        dogId: widget.dogId,
        bytes: picked.bytes,
        filename: picked.name,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Certificate uploaded — staff will record the dates.'),
          backgroundColor: AppColors.success,
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Certificate not saved: ${e.toString().replaceFirst('Exception: ', '')}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _open(VaccinationCertificate certificate) async {
    final removed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VaccinationCertificateScreen(
          certificate: certificate,
          canRemove: certificate.canBeRemovedBy(userId: _myUserId, isStaff: widget.isStaff),
        ),
      ),
    );
    if (removed == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return GroupedSection(
      header: 'Certificates',
      footer: 'PDF or photo, up to 10 MB. Only you and the staff team can see them.',
      children: [
        if (_loading)
          const ListTile(
            leading: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            title: Text('Checking for certificates…'),
          )
        else if (_certificates.isEmpty)
          ListTile(
            leading: const Picon(PiconsDuotone.certificate, color: AppColors.iosSecondaryLabel),
            title: const Text('No certificate on file'),
            subtitle: Text(
              widget.isStaff
                  ? 'Attach the vet\'s certificate here or from the profile.'
                  : "Attach your dog's certificate and staff will record the dates.",
            ),
          )
        else
          for (final certificate in _certificates)
            VaccinationCertificateTile(certificate: certificate, onTap: () => _open(certificate)),
        ListTile(
          leading: _uploading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Picon(PiconsDuotone.paperclip, color: AppColors.primary),
          title: Text(
            _uploading
                ? 'Uploading…'
                : (_certificates.isEmpty ? 'Attach certificate' : 'Attach a new certificate'),
            style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
          ),
          onTap: _uploading ? null : _attach,
        ),
      ],
    );
  }
}
