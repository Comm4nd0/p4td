import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/vaccination_certificate.dart';

String _ukDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// One vaccination certificate in a list: type icon, name, the vaccination
/// date it evidences, size, and who added it. Shared by the dog profile and
/// the edit screen so both describe a certificate the same way.
///
/// There is no thumbnail on purpose: the file is private and has no URL, so
/// a preview would mean downloading it with the auth token just to draw a
/// list row. The full view is one tap away.
class VaccinationCertificateTile extends StatelessWidget {
  final VaccinationCertificate certificate;
  final VoidCallback? onTap;
  final Widget? trailing;

  const VaccinationCertificateTile({
    super.key,
    required this.certificate,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = certificate;
    final parts = <String>[
      if (c.vaccinationDate != null) 'Vaccinated ${_ukDate(c.vaccinationDate!)}',
      c.sizeLabel,
      if (c.uploadedByName != null && c.uploadedByName!.isNotEmpty) 'added by ${c.uploadedByName}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Picon(
        c.isPdf ? PiconsDuotone.filePdf : PiconsDuotone.fileImage,
        color: AppColors.primary,
      ),
      title: Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(parts.join(' · '), style: const TextStyle(fontSize: 12)),
      trailing: trailing ?? (onTap == null ? null : const Picon(PiconsDuotone.caretRight, size: 16)),
      onTap: onTap,
    );
  }
}
