import 'dart:async';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../utils/date_formats.dart';
import '../models/dog.dart';
import '../models/group_media.dart';
import '../services/data_service.dart';
import '../services/media_upload_flow.dart';
import '../services/service_locator.dart';
import '../widgets/feed_item_card.dart';
import '../widgets/dog_typeahead.dart';
import '../widgets/skeleton_loaders.dart';
import '../main.dart';

class FeedScreen extends StatefulWidget {
  final bool isStaff;
  final bool canAddFeedMedia;
  final String? scrollToPostId;

  const FeedScreen({super.key, required this.isStaff, this.canAddFeedMedia = false, this.scrollToPostId});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with RouteAware, WidgetsBindingObserver {
  final DataService _dataService = getIt<DataService>();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  List<GroupMedia> _feed = [];
  List<Dog> _allDogs = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  bool _hasScrolledToPost = false;
  bool _showFilters = false;
  DateTimeRange? _dateRange;
  String? _selectedDogId;

  /// Debounces search keystrokes so we don't rebuild the whole list on every
  /// character typed.
  Timer? _searchDebounce;

  /// One [GlobalKey] per post id, used by [_scrollToPost] to scroll a specific
  /// card into view regardless of its (variable) height. Keys are created lazily
  /// as cards are built and persist across rebuilds so the element stays
  /// attached.
  final Map<String, GlobalKey> _cardKeys = {};

  /// Cached filtered feed. Recomputed only when the feed, search query or date
  /// range change (see [_recomputeFilteredFeed]) rather than on every build.
  List<GroupMedia> _filteredFeed = [];

  /// Recomputes [_filteredFeed] from the current feed, search query and date
  /// range. Call whenever any of those inputs change.
  void _recomputeFilteredFeed() {
    final query = _searchController.text.toLowerCase();
    _filteredFeed = _feed.where((post) {
      // Caption text search
      if (query.isNotEmpty) {
        final caption = post.caption?.toLowerCase() ?? '';
        final uploader = post.uploadedByName.toLowerCase();
        if (!caption.contains(query) && !uploader.contains(query)) {
          return false;
        }
      }
      // Date range filter
      if (_dateRange != null) {
        final postDate = post.createdAt;
        if (postDate.isBefore(_dateRange!.start) ||
            postDate.isAfter(_dateRange!.end.add(const Duration(days: 1)))) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _loadFeed();
    _loadDogs();
  }

  /// Load the next page when the user nears the bottom of the list.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadDogs() async {
    try {
      final dogs = await _dataService.getDogs();
      dogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) setState(() => _allDogs = dogs);
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() {
    // Refresh feed when returning to this screen
    _loadFeed(showLoading: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh feed when app comes to foreground
      _loadFeed(showLoading: false);
    }
  }

  /// (Re)load the feed from the first page. Resets pagination state.
  Future<void> _loadFeed({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _loading = true);
    }

    try {
      final result = await _dataService.getFeedPage(dogId: _selectedDogId, page: 1);
      if (mounted) {
        setState(() {
          _feed = result.items;
          _page = 1;
          _hasMore = result.hasMore;
          _loading = false;
          _recomputeFilteredFeed();
        });
        // Scroll to specific post if requested (e.g. from notification tap)
        if (!_hasScrolledToPost && widget.scrollToPostId != null) {
          _hasScrolledToPost = true;
          _scrollToPost(widget.scrollToPostId!);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        // Only show error snackbar if we were showing loading indicator (interaction)
        // or if the feed is empty (initial load failed)
        if (showLoading || _feed.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to load feed: $e'), backgroundColor: AppColors.error),
          );
        }
      }
    }
  }

  /// Append the next page of the feed for infinite scrolling.
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final result =
          await _dataService.getFeedPage(dogId: _selectedDogId, page: _page + 1);
      if (mounted) {
        setState(() {
          // Guard against duplicates if pages shift between requests.
          final existingIds = _feed.map((m) => m.id).toSet();
          _feed.addAll(result.items.where((m) => !existingIds.contains(m.id)));
          _page += 1;
          _hasMore = result.hasMore;
          _loadingMore = false;
          _recomputeFilteredFeed();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _uploadMedia() async {
    await MediaUploadFlow(
      context: context,
      dataService: _dataService,
      onComplete: _loadFeed,
    ).start();
  }

  Future<void> _deleteMedia(GroupMedia media) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Media'),
        content: const Text('Are you sure you want to delete this?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _dataService.deleteGroupMedia(media.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted'), backgroundColor: AppColors.success),
      );
      _loadFeed();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e'), backgroundColor: AppColors.error),
      );
    }
  }

  /// Debounces search input so the filtered list is recomputed at most once
  /// every ~250ms rather than on every keystroke.
  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(_recomputeFilteredFeed);
    });
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      initialDateRange: _dateRange,
    );
    if (picked != null) {
      setState(() {
        _dateRange = picked;
        _recomputeFilteredFeed();
      });
    }
  }

  Widget _buildFilterBar() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: _showFilters
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                children: [
                  // Search field
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search captions...',
                      prefixIcon: Picon(PiconsDuotone.magnifyingGlass, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: Picon(PiconsDuotone.x, size: 20),
                              onPressed: () {
                                _searchDebounce?.cancel();
                                _searchController.clear();
                                setState(_recomputeFilteredFeed);
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),                    ),
                    onChanged: _onSearchChanged,
                  ),
                  const SizedBox(height: 8),
                  // Date range chip
                  Row(
                    children: [
                      ActionChip(
                        avatar: Picon(PiconsDuotone.calendar, size: 16),
                        label: Text(
                          _dateRange != null
                              ? '${ukDate(_dateRange!.start)} – ${ukDate(_dateRange!.end)}'
                              : 'Date range',
                        ),
                        onPressed: _pickDateRange,
                      ),
                      if (_dateRange != null) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Picon(PiconsDuotone.x, size: 18),
                          onPressed: () => setState(() {
                            _dateRange = null;
                            _recomputeFilteredFeed();
                          }),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                      const Spacer(),
                      if (_searchController.text.isNotEmpty || _dateRange != null || _selectedDogId != null)
                        TextButton(
                          onPressed: () {
                            _searchDebounce?.cancel();
                            _searchController.clear();
                            setState(() {
                              _dateRange = null;
                              _selectedDogId = null;
                              _recomputeFilteredFeed();
                            });
                            _loadFeed();
                          },
                          child: const Text('Clear all'),
                        ),
                    ],
                  ),
                  // Dog filter typeahead
                  if (_allDogs.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DogTypeahead(
                      dogs: _allDogs,
                      selectedDogId: _selectedDogId,
                      hintText: 'Filter by dog...',
                      onSelected: (dogId) {
                        setState(() => _selectedDogId = dogId);
                        _loadFeed();
                      },
                    ),
                  ],
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredFeed;
    final hasActiveFilters = _searchController.text.isNotEmpty || _dateRange != null || _selectedDogId != null;

    return Scaffold(
      floatingActionButton: widget.canAddFeedMedia
          ? FloatingActionButton.extended(
              onPressed: _uploadMedia,
              icon: Picon(PiconsDuotone.plus),
              label: const Text('Upload'),
            )
          : null,
      body: _loading
          ? const FeedSkeletonList()
          : Column(
              children: [
                // Filter toggle button
                if (_feed.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        FilterChip(
                          avatar: Picon(
                            _showFilters ? PiconsDuotone.funnelSimple : PiconsDuotone.funnel,
                            size: 18,
                          ),
                          label: Text(hasActiveFilters
                              ? 'Filters (${filtered.length}/${_feed.length})'
                              : 'Filters'),
                          selected: _showFilters,
                          onSelected: (val) => setState(() => _showFilters = val),
                        ),
                      ],
                    ),
                  ),
                _buildFilterBar(),
                // Feed list
                Expanded(
                  child: RefreshIndicator.adaptive(
                    onRefresh: _loadFeed,
                    child: _feed.isEmpty
                        ? SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: SizedBox(
                              height: MediaQuery.of(context).size.height * 0.6,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Picon(PiconsDuotone.images, size: 64, color: Colors.grey[400]),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No posts yet',
                                      style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                                    ),
                                    if (widget.canAddFeedMedia) ...[
                                      const SizedBox(height: 8),
                                      const Text('Tap the button below to upload photos or videos'),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          )
                        : filtered.isEmpty
                            ? SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: SizedBox(
                                  height: MediaQuery.of(context).size.height * 0.5,
                                  child: Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Picon(PiconsDuotone.magnifyingGlassMinus, size: 64, color: Colors.grey[400]),
                                        const SizedBox(height: 16),
                                        Text(
                                          'No posts match your filters',
                                          style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            : ListView.builder(
                                controller: _scrollController,
                                // +1 row for the loading/“end” footer.
                                itemCount: filtered.length + 1,
                                itemBuilder: (context, index) {
                                  if (index < filtered.length) {
                                    return _buildMediaCard(filtered[index]);
                                  }
                                  return _buildListFooter();
                                },
                              ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Scroll the post with [postId] into view. Height-independent: it looks up
  /// the card's [GlobalKey] and uses [Scrollable.ensureVisible] so it lands
  /// accurately regardless of how tall earlier cards are.
  ///
  /// Cards render lazily, so the target may not be built yet. In that case we
  /// nudge the list toward an estimated offset and retry on the next frames,
  /// giving up after a few attempts rather than scrolling somewhere wrong.
  void _scrollToPost(String postId, {int attempt = 0}) {
    const maxAttempts = 8;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = _filteredFeed.indexWhere((m) => m.id == postId);
      if (index == -1) return; // Not loaded / filtered out — leave the list be.

      final keyContext = _cardKeys[postId]?.currentContext;
      if (keyContext != null) {
        Scrollable.ensureVisible(
          keyContext,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          alignment: 0.1,
        );
        return;
      }

      // Card not built yet: nudge toward a rough offset, then retry.
      if (attempt >= maxAttempts || !_scrollController.hasClients) return;
      final estimatedOffset = index * 450.0;
      _scrollController.animateTo(
        estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
      _scrollToPost(postId, attempt: attempt + 1);
    });
  }

  Widget _buildMediaCard(GroupMedia media) {
    final cardKey = _cardKeys.putIfAbsent(media.id, () => GlobalKey());
    return FeedItemCard(
      key: cardKey,
      media: media,
      isStaff: widget.isStaff,
      canAddFeedMedia: widget.canAddFeedMedia,
      onDelete: _deleteMedia,
      onEdit: _editMedia,
      onReaction: (mediaId, emoji) => _toggleReaction(mediaId, emoji),
      onComment: (mediaId, text) => _addComment(mediaId, text),
    );
  }

  /// Footer row for the feed list: a spinner while the next page loads, and
  /// otherwise empty. Hidden while filters are active (filtering is client-side
  /// over already-loaded items, so paging further wouldn't help).
  Widget _buildListFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return const SizedBox(height: 24);
  }

  Future<void> _editMedia(GroupMedia media) async {
    final result = await showModalBottomSheet<_EditMediaResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _EditMediaSheet(
        media: media,
        allDogs: _allDogs,
      ),
    );
    if (result == null) return;

    try {
      final updated = await _dataService.updateGroupMedia(
        media.id,
        caption: result.caption,
        taggedDogIds: result.taggedDogIds,
      );
      if (!mounted) return;
      setState(() {
        final index = _feed.indexWhere((m) => m.id == media.id);
        if (index != -1) {
          _feed[index] = updated;
        }
        _recomputeFilteredFeed();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Updated successfully'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _addComment(String mediaId, String text) async {
    try {
      await _dataService.addComment(mediaId, text);
      _loadFeed(); // Refresh to show new comment
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding comment: $e')),
        );
      }
    }
  }

  Future<void> _toggleReaction(String mediaId, String emoji) async {
    try {
      final updatedMedia = await _dataService.toggleReaction(mediaId, emoji);
      if (!mounted) return;
      setState(() {
        final index = _feed.indexWhere((m) => m.id == mediaId);
        if (index != -1) {
          _feed[index] = updatedMedia;
        }
        _recomputeFilteredFeed();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

class _EditMediaResult {
  final String caption;
  final List<String> taggedDogIds;

  _EditMediaResult({required this.caption, required this.taggedDogIds});
}

class _EditMediaSheet extends StatefulWidget {
  final GroupMedia media;
  final List<Dog> allDogs;

  const _EditMediaSheet({required this.media, required this.allDogs});

  @override
  State<_EditMediaSheet> createState() => _EditMediaSheetState();
}

class _EditMediaSheetState extends State<_EditMediaSheet> {
  late TextEditingController _captionController;
  late Set<String> _selectedDogIds;

  @override
  void initState() {
    super.initState();
    _captionController = TextEditingController(text: widget.media.caption ?? '');
    _selectedDogIds = widget.media.taggedDogs.map((d) => d.id).toSet();
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text(
                    'Edit Post',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(
                        context,
                        _EditMediaResult(
                          caption: _captionController.text.trim(),
                          taggedDogIds: _selectedDogIds.toList(),
                        ),
                      );
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
            const Divider(),
            // Content
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                children: [
                  // Caption
                  const Text(
                    'Caption',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _captionController,
                    decoration: const InputDecoration(
                      hintText: 'Write a caption (optional)',                      isDense: true,
                    ),
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: 20),
                  // Tagged dogs
                  const Text(
                    'Tagged Dogs',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  if (widget.allDogs.isNotEmpty)
                    DogMultiSelectTypeahead(
                      dogs: widget.allDogs,
                      selectedDogIds: _selectedDogIds,
                      onChanged: (updated) {
                        setState(() => _selectedDogIds = updated);
                      },
                    )
                  else
                    Text('No dogs available', style: TextStyle(color: Colors.grey[500])),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
