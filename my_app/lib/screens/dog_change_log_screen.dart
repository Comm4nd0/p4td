import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/dog_change_log.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/dog_change_log_tile.dart';
import '../widgets/page_body.dart';
import '../widgets/skeleton_loaders.dart';

/// The full change log — every entry, newest first, each expanded to show
/// its field diffs. Staff-only: `/api/dog-change-logs/` refuses owners.
/// Pass [dogId] for one dog's trail (the profile's Change Log tile); without
/// it this is the master log the dashboard's Recent Changes opens into.
class DogChangeLogScreen extends StatefulWidget {
  final String? dogId;
  final String? dogName;

  const DogChangeLogScreen({super.key, this.dogId, this.dogName});

  @override
  State<DogChangeLogScreen> createState() => _DogChangeLogScreenState();
}

class _DogChangeLogScreenState extends State<DogChangeLogScreen> {
  final DataService _dataService = getIt<DataService>();
  List<DogChangeLog> _entries = [];
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await _dataService.getDogChangeLogs(dogId: widget.dogId);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.dogName != null ? '${widget.dogName} — Change Log' : 'Change Log'),
      ),
      body: PageBody(
        child: _loading
            ? const ListTileSkeletonList()
            : RefreshIndicator.adaptive(
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
                                  const Picon(PiconsDuotone.clockCounterClockwise,
                                      size: 48, color: AppColors.primary),
                                  const SizedBox(height: 12),
                                  Text(
                                    widget.dogName != null
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
                              showDog: widget.dogId == null,
                              initiallyExpanded: true,
                            ),
                          ),
              ),
      ),
    );
  }
}
