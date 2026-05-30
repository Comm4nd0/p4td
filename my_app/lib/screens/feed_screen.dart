import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../constants/app_colors.dart';
import '../utils/date_formats.dart';
import '../models/dog.dart';
import '../models/group_media.dart';
import '../services/data_service.dart';
import '../widgets/feed_item_card.dart';
import '../widgets/dog_typeahead.dart';
import '../widgets/media_tag_dialog.dart';
import '../widgets/skeleton_loaders.dart';
import 'multi_photo_capture_screen.dart';
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
  final _dataService = ApiDataService();
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

  /// Filtered feed based on search query and date range.
  List<GroupMedia> get _filteredFeed {
    final query = _searchController.text.toLowerCase();
    return _feed.where((post) {
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
            SnackBar(content: Text('Failed to load feed: $e'), backgroundColor: Colors.red),
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
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _uploadMedia() async {
    final picker = ImagePicker();

    // Show options
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: PhosphorIcon(PhosphorIconsDuotone.camera),
              title: const Text('Take Photos'),
              subtitle: const Text('Capture one or more shots in a row'),
              onTap: () => Navigator.pop(context, 'camera_photo'),
            ),
            ListTile(
              leading: PhosphorIcon(PhosphorIconsDuotone.videoCamera),
              title: const Text('Record Video'),
              onTap: () => Navigator.pop(context, 'camera_video'),
            ),
            const Divider(),
            ListTile(
              leading: PhosphorIcon(PhosphorIconsDuotone.uploadSimple),
              title: const Text('Upload'),
              onTap: () => Navigator.pop(context, 'multiple'),
            ),
          ],
        ),
      ),
    );

    if (choice == null) return;

    // Handle multiple photos upload from gallery
    if (choice == 'multiple') {
      await _uploadMultiplePhotos(picker);
      return;
    }

    // Multi-shot camera capture
    if (choice == 'camera_photo') {
      await _captureFromCamera();
      return;
    }

    // Single video capture (camera) or gallery video pick — single file flow.
    XFile? file;
    final isVideo = choice.contains('video');
    final source = choice.contains('camera') ? ImageSource.camera : ImageSource.gallery;

    if (isVideo) {
      file = await picker.pickVideo(source: source);
    } else {
      file = await picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
    }

    if (file == null) return;
    final pickedFile = file;

    // Show tagging dialog
    final bytes = await pickedFile.readAsBytes();
    final tagResult = await Navigator.push<MediaTagResult>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => MediaTagDialog(files: [(bytes, pickedFile.name, isVideo)]),
      ),
    );
    if (tagResult == null) return; // User cancelled

    // Use the (possibly cropped) bytes returned from the tag dialog.
    final uploadBytes = tagResult.bytesByFile.isNotEmpty
        ? tagResult.bytesByFile[0]
        : bytes;

    // Upload
    try {
      _showUploadingDialog();
      await _dataService.uploadGroupMedia(
        fileBytes: uploadBytes,
        fileName: pickedFile.name,
        isVideo: isVideo,
        caption: tagResult.caption,
        taggedDogIds: tagResult.taggedDogIdsByFile.isNotEmpty
            ? tagResult.taggedDogIdsByFile[0]
            : null,
      );
      if (mounted) {
        Navigator.pop(context); // Close uploading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload successful!'), backgroundColor: Colors.green),
        );
        _loadFeed();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close uploading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _uploadMultiplePhotos(ImagePicker picker) async {
    // Pick multiple media (images and videos)
    final files = await picker.pickMultipleMedia();
    if (files.isEmpty) return;

    // Prepare files
    final fileData = <(Uint8List, String)>[];
    final tagDialogFiles = <(Uint8List, String, bool)>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      final ext = file.name.toLowerCase();
      final isVideo = ext.endsWith('.mp4') || ext.endsWith('.mov') || ext.endsWith('.avi');
      fileData.add((bytes, file.name));
      tagDialogFiles.add((bytes, file.name, isVideo));
    }

    await _processAndUploadFiles(fileData, tagDialogFiles);
  }

  Future<void> _captureFromCamera() async {
    final captured = await Navigator.push<List<(Uint8List, String)>>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const MultiPhotoCaptureScreen(),
      ),
    );
    if (captured == null || captured.isEmpty) return;

    final tagDialogFiles =
        captured.map((p) => (p.$1, p.$2, false)).toList();
    await _processAndUploadFiles(captured, tagDialogFiles);
  }

  /// Shared tag-prompt + batch upload pipeline used by both gallery multi-pick
  /// and in-app multi-photo capture.
  Future<void> _processAndUploadFiles(
    List<(Uint8List, String)> fileData,
    List<(Uint8List, String, bool)> tagDialogFiles,
  ) async {
    final total = fileData.length;
    // Ask whether to tag or upload straight away
    if (!mounted) return;
    final wantTag = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$total file${total == 1 ? '' : 's'} selected'),
        content: const Text('Would you like to tag dogs and add a caption, or upload straight away?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Upload Now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tag & Caption')),
        ],
      ),
    );
    if (wantTag == null) return; // User cancelled

    List<String?>? captionsByFile;
    List<List<String>>? taggedDogIdsByFile;

    if (wantTag) {
      final tagResult = await Navigator.push<MediaTagResult>(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => MediaTagDialog(files: tagDialogFiles),
        ),
      );
      if (tagResult == null) return; // User cancelled
      captionsByFile = tagResult.captionsByFile;
      taggedDogIdsByFile = tagResult.taggedDogIdsByFile;
      // Replace the per-file bytes with whatever the user cropped to (or
      // original bytes for items they left alone / videos).
      if (tagResult.bytesByFile.length == fileData.length) {
        for (var i = 0; i < fileData.length; i++) {
          fileData[i] = (tagResult.bytesByFile[i], fileData[i].$2);
        }
      }
    }

    // Show progress dialog using a ValueNotifier so we can update it in place
    final progress = ValueNotifier<int>(0);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (context, completed, _) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Uploading $completed/$total...'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: total > 0 ? completed / total : 0),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final failures = await _dataService.uploadMultipleGroupMedia(
        files: fileData,
        captionsByFile: captionsByFile,
        taggedDogIdsByFile: taggedDogIdsByFile,
        onProgress: (done, count) {
          progress.value = done;
        },
      );
      if (!mounted) return;
      Navigator.pop(context); // Close progress dialog

      final succeeded = total - failures.length;
      if (failures.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully uploaded $total file${total == 1 ? '' : 's'}!'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        final failedNames = failures.map((f) => f.fileName).join(', ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded $succeeded/$total. Failed: $failedNames'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 6),
          ),
        );
      }
      if (succeeded > 0) _loadFeed();
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showUploadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Uploading...'),
          ],
        ),
      ),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted'), backgroundColor: Colors.green),
      );
      _loadFeed();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e'), backgroundColor: Colors.red),
      );
    }
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
      setState(() => _dateRange = picked);
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
                      prefixIcon: PhosphorIcon(PhosphorIconsDuotone.magnifyingGlass, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: PhosphorIcon(PhosphorIconsDuotone.x, size: 20),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {});
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  // Date range chip
                  Row(
                    children: [
                      ActionChip(
                        avatar: PhosphorIcon(PhosphorIconsDuotone.calendar, size: 16),
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
                          icon: PhosphorIcon(PhosphorIconsDuotone.x, size: 18),
                          onPressed: () => setState(() => _dateRange = null),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                      const Spacer(),
                      if (_searchController.text.isNotEmpty || _dateRange != null || _selectedDogId != null)
                        TextButton(
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _dateRange = null;
                              _selectedDogId = null;
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
              icon: PhosphorIcon(PhosphorIconsDuotone.plus),
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
                          avatar: PhosphorIcon(
                            _showFilters ? PhosphorIconsDuotone.funnelSimple : PhosphorIconsDuotone.funnel,
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
                  child: RefreshIndicator(
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
                                    PhosphorIcon(PhosphorIconsDuotone.images, size: 64, color: Colors.grey[400]),
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
                                        PhosphorIcon(PhosphorIconsDuotone.magnifyingGlassMinus, size: 64, color: Colors.grey[400]),
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

  void _scrollToPost(String postId) {
    // Wait for the list to render, then scroll to the post
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final index = _feed.indexWhere((m) => m.id == postId);
      if (index != -1 && _scrollController.hasClients) {
        // Estimate position: each card is roughly 450px tall.
        // Use animateTo to scroll close to the target post.
        final estimatedOffset = index * 450.0;
        _scrollController.animateTo(
          estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  Widget _buildMediaCard(GroupMedia media) {
    return FeedItemCard(
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
      setState(() {
        final index = _feed.indexWhere((m) => m.id == media.id);
        if (index != -1) {
          _feed[index] = updated;
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Updated successfully'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e'), backgroundColor: Colors.red),
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
      setState(() {
        final index = _feed.indexWhere((m) => m.id == mediaId);
        if (index != -1) {
          _feed[index] = updatedMedia;
        }
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
                      hintText: 'Write a caption (optional)',
                      border: OutlineInputBorder(),
                      isDense: true,
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
