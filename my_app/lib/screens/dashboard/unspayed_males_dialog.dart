import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../services/data_service.dart';

/// Read-only dialog listing male dogs over a year old that aren't yet marked
/// spayed/neutered, prompting staff to confirm with the owner.
///
/// Extracted verbatim from [UnifiedDashboardScreen] (audit F14).
Future<void> showUnspayedMalesDialog(
  BuildContext context,
  List<UnspayedMaleSummary> unspayedMales,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Spay status to confirm'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'These male dogs are over 1 year old and not yet marked as spayed/neutered. '
            'Please ask the owner whether their dog has been spayed yet.',
          ),
          const SizedBox(height: 12),
          ...unspayedMales.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Picon(PiconsDuotone.dog, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(d.name)),
                  ],
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
