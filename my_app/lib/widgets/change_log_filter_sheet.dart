import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/dog_change_log.dart';

/// The change log's Filters sheet. Returns the filter to apply, or null when
/// dismissed. [dogs] is null on a single dog's log, where the dog is fixed.
Future<DogChangeLogFilter?> showChangeLogFilterSheet(
  BuildContext context, {
  required DogChangeLogFilter filter,
  required List<Dog>? dogs,
  required List<DogChangeActor> actors,
}) {
  return showModalBottomSheet<DogChangeLogFilter>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ChangeLogFilterSheet(filter: filter, dogs: dogs, actors: actors),
  );
}

class _ChangeLogFilterSheet extends StatefulWidget {
  final DogChangeLogFilter filter;
  final List<Dog>? dogs;
  final List<DogChangeActor> actors;

  const _ChangeLogFilterSheet({required this.filter, required this.dogs, required this.actors});

  @override
  State<_ChangeLogFilterSheet> createState() => _ChangeLogFilterSheetState();
}

class _ChangeLogFilterSheetState extends State<_ChangeLogFilterSheet> {
  late DogChangeLogFilter _filter = widget.filter;

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: _filter.from != null && _filter.to != null
          ? DateTimeRange(start: _filter.from!, end: _filter.to!)
          : null,
    );
    if (picked != null) {
      setState(() => _filter = _filter.copyWith(from: picked.start, to: picked.end));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dogs = widget.dogs == null
        ? null
        : ([...widget.dogs!]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())));
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Filter changes',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (dogs != null) ...[
            DropdownButtonFormField<String?>(
              key: const Key('filter-dog'),
              initialValue: dogs.any((d) => d.id == _filter.dogId) ? _filter.dogId : null,
              decoration: const InputDecoration(labelText: 'Dog'),
              isExpanded: true,
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Any dog')),
                for (final dog in dogs) DropdownMenuItem<String?>(value: dog.id, child: Text(dog.name)),
              ],
              onChanged: (id) => setState(() => _filter = _filter.copyWith(
                    dogId: id,
                    dogName: id == null ? null : dogs.firstWhere((d) => d.id == id).name,
                  )),
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<String?>(
            key: const Key('filter-actor'),
            initialValue: widget.actors.any((a) => a.queryValue == _filter.actorId) ? _filter.actorId : null,
            decoration: const InputDecoration(labelText: 'Changed by'),
            isExpanded: true,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Anyone')),
              for (final actor in widget.actors)
                DropdownMenuItem<String?>(value: actor.queryValue, child: Text(actor.name)),
            ],
            onChanged: (value) => setState(() => _filter = _filter.copyWith(
                  actorId: value,
                  actorName: value == null
                      ? null
                      : widget.actors.firstWhere((a) => a.queryValue == value).name,
                )),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: const Key('filter-action'),
            initialValue: _filter.action,
            decoration: const InputDecoration(labelText: 'Type of change'),
            isExpanded: true,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Any change')),
              for (final entry in dogChangeActionLabels.entries)
                DropdownMenuItem<String?>(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) => setState(() => _filter = _filter.copyWith(action: value)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDates,
                  icon: const Picon(PiconsDuotone.calendarBlank, size: 16),
                  label: Text(_filter.hasDates ? _filter.datesLabel : 'Any time'),
                ),
              ),
              if (_filter.hasDates)
                IconButton(
                  tooltip: 'Clear dates',
                  icon: const Picon(PiconsDuotone.x, size: 18),
                  onPressed: () => setState(() => _filter = _filter.withoutDates()),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              TextButton(
                onPressed: _filter.isEmpty
                    ? null
                    : () => Navigator.pop(context, DogChangeLogFilter.none),
                child: const Text('Clear all'),
              ),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                onPressed: () => Navigator.pop(context, _filter),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
