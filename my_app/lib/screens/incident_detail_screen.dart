import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/incident.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/defect_comments_section.dart';
import '../widgets/feed_item_card.dart' show VideoPlayerWidget;

/// The full record of one incident: who was involved, what happened, what was
/// done, the photos, and the follow-up thread. Staff-only — the API refuses
/// owners on every route this screen calls.
class IncidentDetailScreen extends StatefulWidget {
  final int incidentId;

  const IncidentDetailScreen({super.key, required this.incidentId});

  @override
  State<IncidentDetailScreen> createState() => _IncidentDetailScreenState();
}

class _IncidentDetailScreenState extends State<IncidentDetailScreen> {
  final DataService _dataService = getIt<DataService>();
  final ImagePicker _picker = ImagePicker();
  Incident? _incident;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final incident = await _dataService.getIncident(widget.incidentId);
      if (!mounted) return;
      setState(() {
        _incident = incident;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load incident: $e')),
      );
    }
  }

  Future<void> _addMedia() async {
    try {
      final files = await _picker.pickMultipleMedia(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (files.isEmpty) return;
      final media = <(Uint8List, String)>[];
      for (final file in files) {
        media.add((await file.readAsBytes(), file.name));
      }
      final updated = await _dataService.addIncidentMedia(widget.incidentId, media);
      if (mounted) setState(() => _incident = updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add media: $e')),
      );
    }
  }

  Future<void> _changeStatus() async {
    final incident = _incident;
    if (incident == null) return;
    final newStatus = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Set incident status', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            _statusOption(sheetContext, 'OPEN', 'Open', incident.status),
            _statusOption(sheetContext, 'MONITORING', 'Monitoring', incident.status),
            _statusOption(sheetContext, 'RESOLVED', 'Resolved', incident.status),
          ],
        ),
      ),
    );
    if (newStatus == null || newStatus == incident.status || !mounted) return;

    String? notes;
    if (newStatus == 'RESOLVED') {
      notes = await _askResolutionNotes();
      if (!mounted) return;
    }
    try {
      final updated = await _dataService.changeIncidentStatus(
        incident.id,
        newStatus,
        resolutionNotes: notes,
      );
      if (!mounted) return;
      setState(() => _incident = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Incident marked ${updated.statusDisplay.toLowerCase()}'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update status: $e')),
      );
    }
  }

  Future<String?> _askResolutionNotes() async {
    final controller = TextEditingController();
    final notes = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('How was it closed out?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Optional — wound healed, dogs kept apart, owner happy…',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext), child: const Text('Skip')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    return (notes == null || notes.isEmpty) ? null : notes;
  }

  Future<void> _toggleOwnerNotified(IncidentDog entry) async {
    try {
      final updated = await _dataService.setIncidentOwnerNotified(
        widget.incidentId,
        entry.dogId,
        !entry.ownerNotified,
      );
      if (mounted) setState(() => _incident = updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update: $e')),
      );
    }
  }

  Future<void> _addComment(String text) async {
    final updated = await _dataService.addIncidentComment(widget.incidentId, text);
    if (mounted) setState(() => _incident = updated);
  }

  Widget _statusOption(BuildContext context, String value, String label, String current) {
    final color = incidentStatusColor(value);
    return ListTile(
      leading: Picon(
        value == 'RESOLVED' ? PiconsDuotone.checkCircle : PiconsDuotone.firstAidKit,
        color: color,
      ),
      title: Text(label),
      trailing: current == value ? Picon(PiconsDuotone.check, color: color) : null,
      onTap: () => Navigator.pop(context, value),
    );
  }

  void _openMedia(int initialIndex) {
    final incident = _incident;
    if (incident == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _IncidentMediaViewer(media: incident.media, initialIndex: initialIndex),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final incident = _incident;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Incident'),
        actions: [
          if (incident != null)
            TextButton(onPressed: _changeStatus, child: const Text('Set Status')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : incident == null
              ? const Center(child: Text('Incident not found'))
              : RefreshIndicator.adaptive(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildHeaderCard(incident),
                      const SizedBox(height: 16),
                      _buildDogsSection(incident),
                      const SizedBox(height: 16),
                      _buildDetailSection(incident),
                      const SizedBox(height: 16),
                      _buildMediaSection(incident),
                      const Divider(height: 32),
                      DefectCommentsSection(
                        comments: incident.comments,
                        onSubmit: _addComment,
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
  }

  Widget _buildHeaderCard(Incident incident) {
    final statusColor = incidentStatusColor(incident.status);
    final severityColor = incidentSeverityColor(incident.severity);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    incident.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                ),
                _badge(incident.statusDisplay, statusColor),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _badge(incident.severityDisplay, severityColor),
                Text(incident.typeDisplay, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                Text('· ${ukDateTimeWithDay(incident.occurredAt.toLocal())}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                if (incident.location.isNotEmpty)
                  Text('· ${incident.location}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Logged by ${incident.reportedByName ?? 'staff'}'
              '${incident.staffPresentNames.isNotEmpty ? ' · present: ${incident.staffPresentNames.join(", ")}' : ''}',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            if (incident.resolvedAt != null)
              Text(
                'Resolved ${ukDateTime(incident.resolvedAt!.toLocal())}'
                '${incident.resolvedByName != null ? ' by ${incident.resolvedByName}' : ''}',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDogsSection(Incident incident) {
    if (incident.dogsInvolved.isEmpty) {
      return Text('No dogs named on this incident',
          style: TextStyle(color: Colors.grey[600]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Dogs involved',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        for (final entry in incident.dogsInvolved)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Picon(PiconsDuotone.pawPrint, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(entry.dogName,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      _badge(entry.roleDisplay, AppColors.primary),
                    ],
                  ),
                  if (entry.injuries.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(entry.injuries, style: const TextStyle(fontSize: 13)),
                  ],
                  const SizedBox(height: 4),
                  // Whether the owner has been told is tracked here rather
                  // than shown to them — they hear it from staff, not the app.
                  InkWell(
                    onTap: () => _toggleOwnerNotified(entry),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Picon(
                            entry.ownerNotified
                                ? PiconsDuotone.checkCircle
                                : PiconsDuotone.circle,
                            size: 18,
                            color: entry.ownerNotified ? AppColors.success : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.ownerNotified
                                ? '${entry.ownerName ?? 'Owner'} has been told'
                                : 'Owner not told yet',
                            style: TextStyle(
                              fontSize: 12,
                              color: entry.ownerNotified ? AppColors.success : Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDetailSection(Incident incident) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _detailBlock('What happened', incident.description),
        _detailBlock('Injuries', incident.injuries),
        _detailBlock('Action taken', incident.actionTaken),
        if (incident.vetRequired)
          _detailBlock(
            'Vet',
            incident.vetDetails.trim().isEmpty ? 'Vet involved / needed' : incident.vetDetails,
          ),
        _detailBlock('Resolution', incident.resolutionNotes),
      ],
    );
  }

  Widget _detailBlock(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey[700])),
          const SizedBox(height: 4),
          Text(value),
        ],
      ),
    );
  }

  Widget _buildMediaSection(Incident incident) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Photos & video',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Spacer(),
            TextButton.icon(
              onPressed: _addMedia,
              icon: Picon(PiconsDuotone.cameraPlus, size: 20),
              label: const Text('Add'),
            ),
          ],
        ),
        if (incident.media.isEmpty)
          Text('Nothing attached', style: TextStyle(color: Colors.grey[600]))
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: incident.media.length,
            itemBuilder: (context, index) {
              final item = incident.media[index];
              final url = item.thumbnailUrl ?? (item.isVideo ? null : item.fileUrl);
              return GestureDetector(
                onTap: () => _openMedia(index),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (url != null)
                        CachedNetworkImage(imageUrl: url, fit: BoxFit.cover)
                      else
                        Container(color: Colors.grey[300]),
                      if (item.isVideo)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                                color: Colors.black54, shape: BoxShape.circle),
                            child: Picon(PiconsDuotone.play, color: Colors.white, size: 20),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11),
      ),
    );
  }
}

/// Full-screen pager over an incident's photos and video.
class _IncidentMediaViewer extends StatefulWidget {
  final List<IncidentMedia> media;
  final int initialIndex;

  const _IncidentMediaViewer({required this.media, required this.initialIndex});

  @override
  State<_IncidentMediaViewer> createState() => _IncidentMediaViewerState();
}

class _IncidentMediaViewerState extends State<_IncidentMediaViewer> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_currentIndex + 1} of ${widget.media.length}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemCount: widget.media.length,
        itemBuilder: (context, index) {
          final item = widget.media[index];
          final url = item.fileUrl;
          if (url == null) {
            return const Center(
                child: Icon(Icons.broken_image, color: Colors.white54, size: 48));
          }
          if (item.isVideo) {
            return Center(
              child: VideoPlayerWidget(url: url, thumbnail: item.thumbnailUrl),
            );
          }
          return InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(child: CachedNetworkImage(imageUrl: url)),
          );
        },
      ),
    );
  }
}
