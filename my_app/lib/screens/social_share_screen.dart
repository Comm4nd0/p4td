import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/group_media.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/media_actions.dart';

/// Staff picker for sharing multiple feed photos to social media.
///
/// Opened from the dashboard Quick Actions ("Share to Socials"). Shows feed
/// photos newest-first (the feed endpoint orders by `-created_at`) in a
/// multi-select grid; "Share" downloads the selected images and opens the
/// system share sheet, where staff pick Facebook, Instagram or any other
/// installed app. Selection order is preserved, so it becomes the photo
/// order of the resulting post.
class SocialShareScreen extends StatefulWidget {
  const SocialShareScreen({super.key});

  @override
  State<SocialShareScreen> createState() => _SocialShareScreenState();
}

class _SocialShareScreenState extends State<SocialShareScreen> {
  final DataService _dataService = getIt<DataService>();
  final ScrollController _scrollController = ScrollController();

  final List<GroupMedia> _photos = [];

  /// Selected photos in tap order.
  final List<GroupMedia> _selected = [];

  int _nextPage = 1;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  /// Bumped on pull-to-refresh so an in-flight page load from before the
  /// refresh can't append stale items to the freshly cleared list.
  int _generation = 0;

  bool _preparing = false;
  int _prepared = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // A feed page can be all videos; keep fetching (bounded) until this
      // batch adds a screenful of photos or the feed runs out, so the grid
      // grows enough for the scroll listener to take over again.
      var added = 0;
      var fetches = 0;
      while (_hasMore && added < 12 && fetches < 5) {
        final page = await _dataService.getFeedPage(page: _nextPage);
        if (gen != _generation) return;
        fetches++;
        _nextPage++;
        _hasMore = page.hasMore;
        final photos = page.items.where((m) => m.isPhoto).toList();
        _photos.addAll(photos);
        added += photos.length;
      }
    } catch (e) {
      if (gen == _generation) _error = '$e';
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    _generation++;
    setState(() {
      _photos.clear();
      _nextPage = 1;
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    await _loadMore();
  }

  void _toggleSelected(GroupMedia photo) {
    if (_preparing) return;
    setState(() {
      final index = _selected.indexWhere((p) => p.id == photo.id);
      if (index >= 0) {
        _selected.removeAt(index);
      } else {
        _selected.add(photo);
      }
    });
  }

  Future<void> _shareSelected(BuildContext buttonContext) async {
    if (_selected.isEmpty || _preparing) return;
    final urls = _selected.map((p) => p.fileUrl).toList();
    setState(() {
      _preparing = true;
      _prepared = 0;
    });
    try {
      await shareImages(
        buttonContext,
        urls,
        onProgress: (done, total) {
          if (mounted) setState(() => _prepared = done);
        },
      );
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Share to Socials'),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: _preparing
                  ? null
                  : () => setState(() => _selected.clear()),
              child: const Text('Clear'),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Newest photos first. Tap to select, then share to Facebook, '
              'Instagram or another app.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: _buildContent(theme)),
        ],
      ),
      bottomNavigationBar: _buildShareBar(theme),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_error != null && _photos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load the feed: $_error',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _loadMore,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_photos.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_photos.isEmpty && !_hasMore) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No photos in the feed yet.'),
        ),
      );
    }

    // Size the decoded bitmap to the grid cell (3 columns) so we don't
    // decode full-resolution images for tiny thumbnails.
    final media = MediaQuery.of(context);
    final cellWidth = (media.size.width - 4 * 2 - 4 * 2) / 3;
    final cellCacheWidth = (media.devicePixelRatio * cellWidth).round();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: GridView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: _photos.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _photos.length) {
            // A failed page load becomes a tap-to-retry tile — auto-retrying
            // from the builder would hammer the API on a persistent error.
            if (_error != null) {
              return Center(
                child: IconButton(
                  onPressed: _loadMore,
                  icon: Picon(PiconsDuotone.arrowClockwise),
                  tooltip: 'Retry',
                ),
              );
            }
            // Loader tile: reaching it means the user is at the end of what
            // has loaded, so kick off the next page (also covers screens tall
            // enough that the scroll listener never fires).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _loadMore();
            });
            return const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return _buildPhotoTile(theme, _photos[index], cellCacheWidth);
        },
      ),
    );
  }

  Widget _buildPhotoTile(ThemeData theme, GroupMedia photo, int cacheWidth) {
    final selectedIndex = _selected.indexWhere((p) => p.id == photo.id);
    final isSelected = selectedIndex >= 0;
    return GestureDetector(
      onTap: () => _toggleSelected(photo),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: photo.thumbnailUrl ?? photo.fileUrl,
              memCacheWidth: cacheWidth,
              fit: BoxFit.cover,
              placeholder: (context, url) =>
                  Container(color: theme.colorScheme.surfaceContainerHighest),
              errorWidget: (context, url, error) => Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Picon(PiconsDuotone.warningCircle),
              ),
            ),
            if (isSelected) Container(color: Colors.black26),
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.black26,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: isSelected
                    ? Text(
                        '${selectedIndex + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareBar(ThemeData theme) {
    final count = _selected.length;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outline, width: 0.5),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      count == 0
                          ? 'Select photos to share'
                          : '$count photo${count == 1 ? '' : 's'} selected',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (count > 10)
                      Text(
                        'Instagram allows up to 10 photos per post',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Builder so the share popover (iPad) anchors to this button.
              Builder(
                builder: (buttonContext) => FilledButton.icon(
                  onPressed: count == 0 || _preparing
                      ? null
                      : () => _shareSelected(buttonContext),
                  icon: _preparing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Picon(PiconsDuotone.shareNetwork, size: 18),
                  label: Text(
                    _preparing ? 'Preparing $_prepared/$count…' : 'Share',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
