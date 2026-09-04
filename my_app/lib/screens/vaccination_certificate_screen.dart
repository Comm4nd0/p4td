import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/vaccination_certificate.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/page_body.dart';

/// Shows one vaccination certificate.
///
/// The file is fetched with the auth token through the gated download view —
/// it has no URL, so nothing here uses CachedNetworkImage or the image cache.
/// Photos are shown in a zoomable viewer; PDFs are handed to the OS document
/// viewer from a copy in the app's temporary directory, which the OS clears.
///
/// Returns `true` to the caller if the certificate was removed here.
class VaccinationCertificateScreen extends StatefulWidget {
  final VaccinationCertificate certificate;

  /// Whether to offer "Remove". The server has the final say (staff or the
  /// uploader only) and its message is shown if it refuses.
  final bool canRemove;

  const VaccinationCertificateScreen({
    super.key,
    required this.certificate,
    this.canRemove = false,
  });

  @override
  State<VaccinationCertificateScreen> createState() => _VaccinationCertificateScreenState();
}

class _VaccinationCertificateScreenState extends State<VaccinationCertificateScreen> {
  final DataService _dataService = getIt<DataService>();
  Uint8List? _bytes;
  String? _error;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _bytes = null;
      _error = null;
    });
    try {
      final bytes = await _dataService.downloadVaccinationCertificate(widget.certificate.id);
      if (!mounted) return;
      setState(() => _bytes = bytes);
      if (widget.certificate.isPdf) {
        await _openPdf(bytes);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openPdf(Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/vaccination-certificate-${widget.certificate.id}.pdf');
      await file.writeAsBytes(bytes, flush: true);
      final result = await OpenFilex.open(file.path, type: 'application/pdf');
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the PDF: ${result.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the PDF: $e')),
        );
      }
    }
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove certificate?'),
        content: Text(
          'This removes ${widget.certificate.displayName} from ${widget.certificate.dogName}\'s profile. '
          'The vaccination date itself is not changed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removing = true);
    try {
      await _dataService.deleteVaccinationCertificate(widget.certificate.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _removing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.certificate;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaccination certificate'),
        actions: [
          if (widget.canRemove)
            IconButton(
              tooltip: 'Remove',
              icon: const Picon(PiconsDuotone.trash),
              onPressed: _removing ? null : _remove,
            ),
        ],
      ),
      body: PageBody(child: _body(c)),
    );
  }

  Widget _body(VaccinationCertificate c) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Picon(PiconsDuotone.warningCircle, size: 40, color: AppColors.error),
              const SizedBox(height: 12),
              Text(_error!.replaceFirst('Exception: ', ''), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (_bytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (c.isPdf) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Picon(PiconsDuotone.filePdf, size: 64, color: AppColors.primary),
              const SizedBox(height: 12),
              Text(c.displayName, textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(c.sizeLabel, style: TextStyle(color: Colors.grey[600])),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => _openPdf(_bytes!),
                icon: const Picon(PiconsDuotone.arrowSquareOut, size: 18),
                label: const Text('Open PDF'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 6,
            child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            [
              c.displayName,
              if (c.vaccinationDate != null)
                'Vaccinated ${c.vaccinationDate!.day.toString().padLeft(2, '0')}/${c.vaccinationDate!.month.toString().padLeft(2, '0')}/${c.vaccinationDate!.year}',
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
