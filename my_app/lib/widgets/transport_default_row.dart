import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

/// Staff-only selector for who handles a dog's drop-off or pick-up by
/// default (staff van vs owner), with an optional time when the owner
/// handles it. Used on the add and edit dog screens.
class TransportDefaultRow extends StatelessWidget {
  final String label;
  final bool ownerSelected;
  final TimeOfDay? time;
  final TimeOfDay initialTimeIfUnset;
  final ValueChanged<bool> onOwnerChanged;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final VoidCallback onTimeCleared;

  const TransportDefaultRow({
    super.key,
    required this.label,
    required this.ownerSelected,
    required this.time,
    required this.initialTimeIfUnset,
    required this.onOwnerChanged,
    required this.onTimeChanged,
    required this.onTimeCleared,
  });

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Staff'), icon: Picon(PiconsDuotone.van, size: 18)),
            ButtonSegment(value: true, label: Text('Owner'), icon: Picon(PiconsDuotone.houseLine, size: 18)),
          ],
          selected: {ownerSelected},
          onSelectionChanged: (s) => onOwnerChanged(s.first),
        ),
        if (ownerSelected) ...[
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(
              icon: const Picon(PiconsDuotone.clock, size: 18),
              label: Text(time == null ? 'Set time (optional)' : _fmt(time!)),
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: time ?? initialTimeIfUnset,
                );
                if (picked != null) onTimeChanged(picked);
              },
            ),
            if (time != null) ...[
              const SizedBox(width: 8),
              TextButton(onPressed: onTimeCleared, child: const Text('Clear')),
            ],
          ]),
        ],
      ],
    );
  }
}
