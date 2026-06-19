import 'dart:async';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../constants/app_colors.dart';
import '../models/group_media.dart';
import '../services/cache_service.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';
import '../utils/media_actions.dart';
import 'reaction_picker_sheet.dart';

class FeedItemCard extends StatefulWidget {
  final GroupMedia media;
  final bool isStaff;
  final bool canAddFeedMedia;
  final Function(GroupMedia) onDelete;
  final Function(String, String) onReaction;
  final Function(String, String) onComment;
  final Function(GroupMedia)? onEdit;

  const FeedItemCard({
    super.key,
    required this.media,
    required this.isStaff,
    this.canAddFeedMedia = false,
    required this.onDelete,
    required this.onReaction,
    required this.onComment,
    this.onEdit,
  });

  @override
  State<FeedItemCard> createState() => _FeedItemCardState();
}

class _FeedItemCardState extends State<FeedItemCard> with TickerProviderStateMixin {
  bool _showAllComments = false;
  final TextEditingController _commentController = TextEditingController();
  final DataService _dataService = ApiDataService();

  /// Drives the Instagram-style heart overlay shown on photo double-tap.
  late final AnimationController _heartController;
  late final Animation<double> _heartScale;
  late final Animation<double> _heartOpacity;

  /// Drives the "pop" on the reaction button/pill when a reaction lands.
  late final AnimationController _popController;
  late final Animation<double> _popScale;

  @override
  void initState() {
    super.initState();
    _heartController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _heartScale = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
      parent: _heartController,
      curve: const Interval(0.0, 0.45, curve: Curves.elasticOut),
    ));
    _heartOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(CurvedAnimation(
      parent: _heartController,
      curve: const Interval(0.7, 1.0, curve: Curves.easeOut),
    ));
    _popController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _popScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.35)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.35, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_popController);
  }

  @override
  void didUpdateWidget(covariant FeedItemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The feed screen swaps in a fresh GroupMedia after the API confirms a
    // reaction, so a change here means the user's reaction just landed.
    if (widget.media.userReaction != oldWidget.media.userReaction &&
        widget.media.userReaction != null) {
      _popController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _heartController.dispose();
    _popController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => _showProfilePopup(context),
                  child: CircleAvatar(
                    backgroundColor: AppColors.primaryLight.withOpacity(0.2),
                    backgroundImage: widget.media.uploadedByProfilePhoto != null
                        ? CachedNetworkImageProvider(
                            widget.media.uploadedByProfilePhoto!,
                            maxWidth: 120,
                            maxHeight: 120,
                          )
                        : null,
                    child: widget.media.uploadedByProfilePhoto == null
                        ? Text(
                            widget.media.uploadedByName.isNotEmpty
                              ? widget.media.uploadedByName[0].toUpperCase()
                              : '?',
                            style: TextStyle(color: AppColors.primaryDark),
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showProfilePopup(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.media.uploadedByName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          ukDateTime(widget.media.createdAt),
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.media.isPhoto || widget.canAddFeedMedia || widget.isStaff)
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'share') {
                        shareImage(context, widget.media.fileUrl);
                      } else if (value == 'save') {
                        saveImageToGallery(context, widget.media.fileUrl);
                      } else if (value == 'delete') {
                        widget.onDelete(widget.media);
                      } else if (value == 'edit') {
                        widget.onEdit?.call(widget.media);
                      }
                    },
                    itemBuilder: (context) => [
                      if (widget.media.isPhoto)
                        const PopupMenuItem(
                          value: 'share',
                          child: Row(
                            children: [
                              Picon(PiconsDuotone.shareNetwork),
                              SizedBox(width: 8),
                              Text('Share photo'),
                            ],
                          ),
                        ),
                      if (widget.media.isPhoto)
                        const PopupMenuItem(
                          value: 'save',
                          child: Row(
                            children: [
                              Picon(PiconsDuotone.downloadSimple),
                              SizedBox(width: 8),
                              Text('Save photo'),
                            ],
                          ),
                        ),
                      if (widget.canAddFeedMedia || widget.isStaff)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Picon(PiconsDuotone.pencilSimple),
                              SizedBox(width: 8),
                              Text('Edit'),
                            ],
                          ),
                        ),
                      if (widget.canAddFeedMedia || widget.isStaff)
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Picon(PiconsDuotone.trash, color: Colors.red),
                              SizedBox(width: 8),
                              Text('Delete'),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          // Media content
          if (widget.media.isPhoto)
            GestureDetector(
              onTap: () => _openFullScreenImage(context, widget.media.fileUrl),
              onDoubleTap: _onDoubleTapPhoto,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Semantics(
                    image: true,
                    button: true,
                    label: _photoSemanticLabel(),
                    child: CachedNetworkImage(
                      // Use the lightweight thumbnail in the list; the full-resolution
                      // image is loaded only when opening the full-screen viewer.
                      imageUrl: widget.media.thumbnailUrl ?? widget.media.fileUrl,
                      width: double.infinity,
                      // Decode at the display width (full bleed) rather than the
                      // image's native resolution.
                      memCacheWidth: (MediaQuery.of(context).size.width *
                              MediaQuery.of(context).devicePixelRatio)
                          .round(),
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        height: 200,
                        color: Colors.grey[200],
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                      errorWidget: (context, url, error) => Container(
                        height: 200,
                        color: Colors.grey[300],
                        child: const Center(child: Picon(PiconsDuotone.warningCircle)),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _heartController,
                      builder: (context, _) {
                        if (_heartController.isDismissed) {
                          return const SizedBox.shrink();
                        }
                        return Opacity(
                          opacity: _heartOpacity.value,
                          child: Transform.scale(
                            scale: _heartScale.value,
                            child: const Icon(
                              Icons.favorite,
                              size: 96,
                              color: Colors.white,
                              shadows: [
                                Shadow(color: Colors.black45, blurRadius: 24),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            )
          else
            VideoPlayerWidget(url: widget.media.fileUrl, thumbnail: widget.media.thumbnailUrl),
          // Tagged dogs
          if (widget.media.taggedDogs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: widget.media.taggedDogs.map((dog) => Chip(
                  avatar: dog.profileImageUrl != null
                      ? CircleAvatar(
                          backgroundImage: CachedNetworkImageProvider(
                            dog.profileImageUrl!,
                            maxWidth: 96,
                            maxHeight: 96,
                          ),
                        )
                      : CircleAvatar(
                          backgroundColor: AppColors.primaryLight.withAlpha(40),
                          child: Text(
                            dog.name.isNotEmpty ? dog.name[0].toUpperCase() : '?',
                            style: const TextStyle(fontSize: 10, color: AppColors.primary),
                          ),
                        ),
                  label: Text(dog.name, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )).toList(),
              ),
            ),
          // Caption
          if (widget.media.caption != null && widget.media.caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(widget.media.caption!),
            ),
          
          // Reactions
          // Reactions
          _buildReactionSection(),
          
          // Comments Section
          _buildCommentsSection(),
          
          const SizedBox(height: 8),
          
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildCommentsSection() {
    final comments = widget.media.comments;
    final displayedComments = _showAllComments ? comments : comments.take(2).toList();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (comments.isNotEmpty) const Divider(),
        
        // Comments specific to this version
        if (comments.isNotEmpty && !_showAllComments && comments.length > 2)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: GestureDetector(
              onTap: () => setState(() => _showAllComments = true),
              child: Text(
                'View all ${comments.length} comments',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ),
          ),

        ...displayedComments.map((comment) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    comment.userName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    ukDateTime(comment.createdAt),
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(comment.text),
              ),
            ],
          ),
        )),
        
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _commentController,
                  decoration: InputDecoration(
                    hintText: 'Add a comment...',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  maxLines: null,
                ),
              ),
              IconButton(
                tooltip: 'Send comment',
                onPressed: () {
                  if (_commentController.text.trim().isNotEmpty) {
                    widget.onComment(widget.media.id, _commentController.text.trim());
                    _commentController.clear();
                    setState(() => _showAllComments = true); // Auto expand on new comment
                  }
                },
                icon: Picon(PiconsDuotone.paperPlaneTilt, color: AppColors.primary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds a screen-reader description for the feed photo from its caption
  /// and any tagged dogs. Falls back to a generic description.
  String _photoSemanticLabel() {
    final parts = <String>[];
    final caption = widget.media.caption?.trim();
    if (caption != null && caption.isNotEmpty) parts.add(caption);
    if (widget.media.taggedDogs.isNotEmpty) {
      final names = widget.media.taggedDogs.map((d) => d.name).join(', ');
      parts.add('Tagged: $names');
    }
    final detail = parts.join('. ');
    return detail.isEmpty
        ? 'Feed photo. Double tap to view full screen.'
        : '$detail. Double tap to view full screen.';
  }

  void _openFullScreenImage(BuildContext context, String imageUrl) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _FullScreenImageViewer(imageUrl: imageUrl),
    ));
  }

  void _showProfilePopup(BuildContext context) {
    final photoUrl = widget.media.uploadedByProfilePhoto;
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (photoUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  imageUrl: photoUrl,
                  width: 280,
                  height: 280,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    width: 280,
                    height: 280,
                    color: Colors.grey[300],
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                  errorWidget: (context, url, error) => Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Picon(PiconsDuotone.user, size: 100, color: Colors.grey[600]),
                  ),
                ),
              )
            else
              Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    widget.media.uploadedByName.isNotEmpty
                        ? widget.media.uploadedByName[0].toUpperCase()
                        : '?',
                    style: TextStyle(fontSize: 100, color: AppColors.primaryDark),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                widget.media.uploadedByName,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showReactionDetails() async {
    showModalBottomSheet(
      context: context,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, controller) => FutureBuilder<List<Map<String, dynamic>>>(
          future: _dataService.getReactionDetails(widget.media.id),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return const Center(child: Text('No reactions yet'));
            }

            final reactions = snapshot.data!;
            return ListView.builder(
              controller: controller,
              itemCount: reactions.length,
              itemBuilder: (context, index) {
                final reaction = reactions[index];
                return ListTile(
                  leading: Text(reaction['emoji'], style: const TextStyle(fontSize: 24)),
                  title: Text(reaction['user_name']),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Opens the reaction picker sheet and submits the chosen emoji.
  Future<void> _openReactionPicker() async {
    final emoji = await showReactionPickerSheet(
      context,
      currentReaction: widget.media.userReaction,
    );
    if (emoji == null) return;
    CacheService().recordRecentReactionEmoji(emoji);
    widget.onReaction(widget.media.id, emoji);
  }

  /// Instagram semantics: double-tap always hearts, never un-hearts.
  void _onDoubleTapPhoto() {
    _heartController.forward(from: 0);
    if (widget.media.userReaction != '❤️') {
      CacheService().recordRecentReactionEmoji('❤️');
      widget.onReaction(widget.media.id, '❤️');
    }
  }

  Widget _buildReactionSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // "Add Reaction" button — opens the picker sheet.
          Tooltip(
            message: 'Add reaction',
            child: InkWell(
              onTap: _openReactionPicker,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: ScaleTransition(
                  scale: _popScale,
                  child: widget.media.userReaction != null
                      ? Picon(PiconsFill.thumbsUp, color: AppColors.primary, size: 20)
                      : Picon(PiconsDuotone.thumbsUp, color: Colors.grey[600], size: 20),
                ),
              ),
            ),
          ),

          // Existing reactions
          if (widget.media.reactions.isNotEmpty)
            ...widget.media.reactions.entries.map((entry) {
              final isMyReaction = widget.media.userReaction == entry.key;
              final pill = GestureDetector(
                onTap: _showReactionDetails,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isMyReaction ? AppColors.primary.withOpacity(0.1) : Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isMyReaction ? AppColors.primaryLight.withOpacity(0.4) : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.key, style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 4),
                      Text(
                        entry.value.toString(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isMyReaction ? FontWeight.bold : FontWeight.normal,
                          color: isMyReaction ? AppColors.primaryDark : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
              );
              // The user's own pill pops alongside the trigger icon.
              return isMyReaction
                  ? ScaleTransition(scale: _popScale, child: pill)
                  : pill;
            }),
        ],
      ),
    );
  }
}

class _FullScreenImageViewer extends StatefulWidget {
  final String imageUrl;

  const _FullScreenImageViewer({required this.imageUrl});

  @override
  State<_FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<_FullScreenImageViewer> {
  bool _saving = false;
  bool _sharing = false;

  Future<void> _saveToDevice() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await saveImageToGallery(context, widget.imageUrl);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await shareImage(context, widget.imageUrl);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Widget _busySpinner() => const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Share',
            onPressed: _sharing ? null : () => _share(),
            icon: _sharing
                ? _busySpinner()
                : const Icon(Icons.ios_share, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Save to device',
            onPressed: _saving ? null : () => _saveToDevice(),
            icon: _saving
                ? _busySpinner()
                : const Icon(Icons.download_rounded, color: Colors.white),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.0,
          child: CachedNetworkImage(
            imageUrl: widget.imageUrl,
            placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
            errorWidget: (context, url, error) => const Picon(PiconsDuotone.warningCircle, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class VideoPlayerWidget extends StatefulWidget {
  final String url;
  final String? thumbnail;

  const VideoPlayerWidget({super.key, required this.url, this.thumbnail});

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _initialized = false;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    await _controller!.initialize();
    if (mounted) {
      setState(() => _initialized = true);
      _controller!.play();
      setState(() => _isPlaying = true);
      _startHideTimer();
    }
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
    setState(() => _isPlaying = !_isPlaying);
    _startHideTimer();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls && _isPlaying) {
      _startHideTimer();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (_isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showControls = false);
      });
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return GestureDetector(
        onTap: _initializeVideo,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.thumbnail != null)
              CachedNetworkImage(
                imageUrl: widget.thumbnail!,
                width: double.infinity,
                height: 250,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  height: 250,
                  color: Colors.grey[200],
                ),
                errorWidget: (context, url, error) => Container(
                  height: 250,
                  color: Colors.grey[300],
                  child: const Center(child: Picon(PiconsDuotone.warningCircle)),
                ),
              )
            else
              Container(
                width: double.infinity,
                height: 250,
                color: Colors.black,
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(50),
              ),
              child: const Picon(PiconsDuotone.play, color: Colors.white, size: 48),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: _toggleControls,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: VideoPlayer(_controller!),
          ),
          // Controls overlay
          if (_showControls) ...[
            // Play/pause button
            GestureDetector(
              onTap: _togglePlayPause,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(50),
                ),
                child: Picon(
                  _isPlaying ? PiconsDuotone.pause : PiconsDuotone.play,
                  color: Colors.white,
                  size: 36,
                ),
              ),
            ),
            // Bottom controls bar
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VideoProgressIndicator(
                      _controller!,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                        playedColor: Colors.white,
                        bufferedColor: Colors.white38,
                        backgroundColor: Colors.white24,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                    ),
                    const SizedBox(height: 2),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _controller!,
                      builder: (context, value, _) => Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(value.position),
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                          Text(
                            _formatDuration(value.duration),
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
