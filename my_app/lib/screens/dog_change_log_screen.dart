import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/dog.dart';
import '../models/dog_change_log.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/badged_action_icon.dart';
import '../widgets/change_log_filter_sheet.dart';
import '../widgets/dog_change_log_tile.dart';
import '../widgets/page_body.dart';
import '../widgets/skeleton_loaders.dart';

/// The full change log — every entry, newest first, each expanded to show
/// its field diffs. Staff-only: `/api/dog-change-logs/` refuses owners.
/// Pass [dogId] for one dog's trail (the profile's Change Log tile); without
/// it this is the master log the dashboard's Recent Changes opens into.
///
/// Filters — dog (master log only), who changed it, the kind of change and
/// a date range — are applied server-side; the active ones sit as chips
/// under the app bar, and the Filters button opens the sheet.
class DogChangeLogScreen extends StatefulWidget {
  final String? dogId;
  final String? dogName;

  /// Open already narrowed (deep links, tests).
  final DogChangeLogFilter initialFilter;

  const DogChangeLogScreen({
    super.key,
    this.dogId,
    this.dogName,
    this.initialFilter = DogChangeLogFilter.none,
  });

  @override
  State<DogChangeLogScreen> createState() => _DogChangeLogScreenState();
}

class _DogChangeLogScreenState extends State<DogChangeLogScreen> {
  final DataService _dataService = getIt<DataService>();
  List<DogChangeLog> _entries = [];
  bool _loading = true;
  bool _loadFailed = false;
  late DogChangeLogFilter _filter = widget.initialFilter;

  // Picker contents for the sheet, fetched once alongside the first page.
  List<Dog>? _dogs;
  List<DogChangeActor> _actors = const [];

  bool get _isMasterLog => widget.dogId == null;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPickers();
  }

  Future<void> _load() async {
    try {
      final entries = await _dataService.getDogChangeLogs(
        dogId: widget.dogId ?? _filter.dogId,
        actorId: _filter.actorId,
        action: _filter.action,
        from: _filter.from,
        to: _filter.to,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  /// Best-effort: a failed picker load just leaves that dropdown empty.
  Future<void> _loadPickers() async {
    final results = await Future.wait<Object?>([
      if (_isMasterLog) _dataService.getDogs().then<Object?>((d) => d, onError: (_) => null),
      _dataService.getDogChangeLogActors().then<Object?>((a) => a, onError: (_) => null),
    ]);
    if (!mounted) return;
    setState(() {
      if (_isMasterLog && results.first is List<Dog>) _dogs = results.first as List<Dog>;
      if (results.last is List<DogChangeActor>) _actors = results.last as List<DogChangeActor>;
    });
  }

  void _apply(DogChangeLogFilter filter) {
    setState(() {
      _filter = filter;
      _loading = true;
    });
    _load();
  }

  Future<void> _openFilters() async {
    final picked = await showChangeLogFilterSheet(
      context,
      filter: _filter,
      dogs: _isMasterLog ? (_dogs ?? const []) : null,
      actors: _actors,
    );
    if (picked != null) _apply(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.dogName != null ? '${widget.dogName} — Change Log' : 'Change Log'),
        actions: [
          BadgedActionIcon(
            icon: PiconsDuotone.funnelSimple,
            count: _filter.count,
            tooltip: 'Filters',
            onPressed: _openFilters,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: PageBody(
        child: Column(
          children: [
            if (!_filter.isEmpty) _FilterBar(filter: _filter, onChanged: _apply),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const ListTileSkeletonList();
    return RefreshIndicator.adaptive(
      onRefresh: _load,
      child: _loadFailed
          ? ListView(children: [
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text('Failed to load the change log. Pull down to retry.',
                      style: TextStyle(color: Colors.grey[600])),
                ),
              ),
            ])
          : _entries.isEmpty
              ? ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Column(children: [
                        const Picon(PiconsDuotone.clockCounterClockwise, size: 48, color: AppColors.primary),
                        const SizedBox(height: 12),
                        Text(
                          !_filter.isEmpty
                              ? 'No changes match these filters'
                              : widget.dogName != null
                                  ? 'No changes recorded for ${widget.dogName} yet'
                                  : 'No changes recorded yet',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ]),
                    ),
                  ),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => DogChangeLogTile(
                    entry: _entries[i],
                    showDog: _isMasterLog,
                    initiallyExpanded: true,
                  ),
                ),
    );
  }
}

/// The active filters as chips; × on a chip drops just that one.
class _FilterBar extends StatelessWidget {
  final DogChangeLogFilter filter;
  final ValueChanged<DogChangeLogFilter> onChanged;

  const _FilterBar({required this.filter, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (filter.hasDog)
        _chip(PiconsDuotone.dog, filter.dogName ?? 'Dog', () => onChanged(filter.withoutDog())),
      if (filter.hasActor)
        _chip(PiconsDuotone.user, filter.actorName ?? 'Someone', () => onChanged(filter.withoutActor())),
      if (filter.hasAction)
        _chip(PiconsDuotone.pencilSimple, filter.actionLabel, () => onChanged(filter.withoutAction())),
      if (filter.hasDates)
        _chip(PiconsDuotone.calendarBlank, filter.datesLabel, () => onChanged(filter.withoutDates())),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Wrap(spacing: 6, runSpacing: -6, children: chips),
          ),
          if (chips.length > 1)
            TextButton(
              onPressed: () => onChanged(DogChangeLogFilter.none),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  Widget _chip(PiconDuotoneData icon, String label, VoidCallback onDeleted) => InputChip(
        avatar: Picon(icon, size: 14, color: AppColors.primary),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onDeleted: onDeleted,
        deleteIconColor: Colors.grey[600],
        visualDensity: VisualDensity.compact,
      );
}
