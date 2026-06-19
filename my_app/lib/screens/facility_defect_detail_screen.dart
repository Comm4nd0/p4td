import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/facility_defect.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';

class FacilityDefectDetailScreen extends StatefulWidget {
  final int defectId;

  const FacilityDefectDetailScreen({
    super.key,
    required this.defectId,
  });

  @override
  State<FacilityDefectDetailScreen> createState() => _FacilityDefectDetailScreenState();
}

class _FacilityDefectDetailScreenState extends State<FacilityDefectDetailScreen> {
  final DataService _dataService = getIt<DataService>();
  final ImagePicker _picker = ImagePicker();
  FacilityDefect? _defect;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDefect();
  }

  Future<void> _loadDefect() async {
    setState(() => _loading = true);
    try {
      final defect = await _dataService.getFacilityDefect(widget.defectId);
      if (mounted) {
        setState(() {
          _defect = defect;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load defect: $e')),
        );
      }
    }
  }

  Future<void> _addPhotos() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage(
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (images.isEmpty) return;
      final photos = <(Uint8List, String)>[];
      for (final image in images) {
        photos.add((await image.readAsBytes(), image.name));
      }
      final updated = await _dataService.addFacilityDefectImages(widget.defectId, photos);
      if (mounted) setState(() => _defect = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add photos: $e')),
        );
      }
    }
  }

  Future<void> _changeStatus() async {
    final defect = _defect;
    if (defect == null) return;
    final newStatus = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Set defect status', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            _statusOption(context, 'REPORTED', 'Reported', AppColors.error, defect.status),
            _statusOption(context, 'IN_PROGRESS', 'In Progress', AppColors.warning, defect.status),
            _statusOption(context, 'RESOLVED', 'Resolved', AppColors.success, defect.status),
          ],
        ),
      ),
    );
    if (newStatus == null || newStatus == defect.status) return;
    try {
      final updated = await _dataService.changeFacilityDefectStatus(defect.id, newStatus);
      if (mounted) {
        setState(() => _defect = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Defect marked ${updated.statusLabel.toLowerCase()}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update status: $e')),
        );
      }
    }
  }

  Widget _statusOption(
      BuildContext context, String value, String label, Color color, String current) {
    return ListTile(
      leading: Picon(
        value == 'RESOLVED' ? PiconsDuotone.checkCircle : PiconsDuotone.warningCircle,
        color: color,
      ),
      title: Text(label),
      trailing: current == value ? Picon(PiconsDuotone.check, color: color) : null,
      onTap: () => Navigator.pop(context, value),
    );
  }

  void _openPhoto(int initialIndex) {
    final defect = _defect;
    if (defect == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FacilityDefectPhotoViewer(
            images: defect.images, initialIndex: initialIndex),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final defect = _defect;
    final statusColor = defect == null
        ? Colors.grey
        : defect.status == 'RESOLVED'
            ? AppColors.success
            : defect.status == 'IN_PROGRESS'
                ? AppColors.warning
                : AppColors.error;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Defect'),
        actions: [
          if (defect != null)
            TextButton(
              onPressed: _changeStatus,
              child: const Text('Set Status'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : defect == null
              ? const Center(child: Text('Defect not found'))
              : RefreshIndicator.adaptive(
                  onRefresh: _loadDefect,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      defect.title,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold, fontSize: 17),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: statusColor.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                          color: statusColor.withValues(alpha: 0.5)),
                                    ),
                                    child: Text(
                                      defect.statusLabel,
                                      style: TextStyle(
                                        color: statusColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${defect.location != null && defect.location!.trim().isNotEmpty ? '${defect.location} · ' : ''}'
                                '${defect.severityLabel} severity',
                                style: TextStyle(color: Colors.grey[600], fontSize: 13),
                              ),
                              if (defect.description != null &&
                                  defect.description!.trim().isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Text(defect.description!),
                              ],
                              const SizedBox(height: 12),
                              Text(
                                'Reported ${ukDateTime(defect.createdAt.toLocal())}'
                                '${defect.reportedByName != null ? ' by ${defect.reportedByName}' : ''}',
                                style: TextStyle(color: Colors.grey[500], fontSize: 12),
                              ),
                              if (defect.resolvedAt != null)
                                Text(
                                  'Resolved ${ukDateTime(defect.resolvedAt!.toLocal())}'
                                  '${defect.resolvedByName != null ? ' by ${defect.resolvedByName}' : ''}',
                                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text('Photos',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _addPhotos,
                            icon: Picon(PiconsDuotone.cameraPlus, size: 20),
                            label: const Text('Add photos'),
                          ),
                        ],
                      ),
                      if (defect.images.isEmpty)
                        Text('No photos attached', style: TextStyle(color: Colors.grey[600]))
                      else
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: defect.images.length,
                          itemBuilder: (context, index) {
                            final image = defect.images[index];
                            final url = image.thumbnailUrl ?? image.imageUrl;
                            return GestureDetector(
                              onTap: () => _openPhoto(index),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: url != null
                                    ? CachedNetworkImage(imageUrl: url, fit: BoxFit.cover)
                                    : Container(color: Colors.grey[200]),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _FacilityDefectPhotoViewer extends StatefulWidget {
  final List<FacilityDefectImage> images;
  final int initialIndex;

  const _FacilityDefectPhotoViewer({required this.images, required this.initialIndex});

  @override
  State<_FacilityDefectPhotoViewer> createState() => _FacilityDefectPhotoViewerState();
}

class _FacilityDefectPhotoViewerState extends State<_FacilityDefectPhotoViewer> {
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
          '${_currentIndex + 1} of ${widget.images.length}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemCount: widget.images.length,
        itemBuilder: (context, index) {
          final url = widget.images[index].imageUrl;
          return InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(
              child: url != null
                  ? CachedNetworkImage(imageUrl: url)
                  : const Icon(Icons.broken_image, color: Colors.white54, size: 48),
            ),
          );
        },
      ),
    );
  }
}
