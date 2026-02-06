import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../models/group_media.dart';

class FeedItemCard extends StatefulWidget {
  final GroupMedia media;
  final bool isStaff;
  final Function(GroupMedia) onDelete;
  final Function(String, String) onReaction;

  const FeedItemCard({
    super.key,
    required this.media,
    required this.isStaff,
    required this.onDelete,
    required this.onReaction,
  });

  @override
  State<FeedItemCard> createState() => _FeedItemCardState();
}

class _FeedItemCardState extends State<FeedItemCard> with SingleTickerProviderStateMixin {
  bool _isExpanded = false;

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
                CircleAvatar(
                  backgroundColor: Colors.blue[100],
                  child: Text(
                    widget.media.uploadedByName.isNotEmpty 
                      ? widget.media.uploadedByName[0].toUpperCase() 
                      : '?',
                    style: TextStyle(color: Colors.blue[800]),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.media.uploadedByName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        DateFormat('d MMM yyyy, HH:mm').format(widget.media.createdAt),
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (widget.isStaff)
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'delete') {
                        widget.onDelete(widget.media);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, color: Colors.red),
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
            CachedNetworkImage(
              imageUrl: widget.media.fileUrl,
              width: double.infinity,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                height: 200,
                color: Colors.grey[200],
                child: const Center(child: CircularProgressIndicator()),
              ),
              errorWidget: (context, url, error) => Container(
                height: 200,
                color: Colors.grey[300],
                child: const Center(child: Icon(Icons.error)),
              ),
            )
          else
            VideoPlayerWidget(url: widget.media.fileUrl, thumbnail: widget.media.thumbnailUrl),
          // Caption
          if (widget.media.caption != null && widget.media.caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(widget.media.caption!),
            ),
          
          // Reactions
          _buildReactionSection(),
          
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildReactionSection() {
    final List<String> commonEmojis = ['❤️', '👍', '😂', '🔥', '🐾'];
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Current reactions count display
          if (widget.media.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: widget.media.reactions.entries.map((entry) {
                  final isMyReaction = widget.media.userReaction == entry.key;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isMyReaction ? Colors.blue[50] : Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isMyReaction ? Colors.blue[200]! : Colors.transparent,
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
                            color: isMyReaction ? Colors.blue[800] : Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          
          // Expandable Reaction Interface
          Row(
            children: [
              if (!_isExpanded)
                // Single Button State
                InkWell(
                  onTap: () {
                    setState(() => _isExpanded = true);
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.media.userReaction ?? '👍', // Show current reaction or default thumb
                          style: const TextStyle(fontSize: 20),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.media.userReaction != null ? 'Reacted' : 'React',
                          style: TextStyle(
                            color: widget.media.userReaction != null ? Colors.blue : Colors.grey[600],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                // Expanded State with Animation
                Expanded(
                  child: Container(
                    height: 50,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(25),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Close button (X)
                        IconButton(
                          icon: const Icon(Icons.close, size: 20, color: Colors.grey),
                          onPressed: () => setState(() => _isExpanded = false),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        // Emojis
                        ...commonEmojis.map((emoji) {
                          final isSelected = widget.media.userReaction == emoji;
                          return InkWell(
                            onTap: () {
                              widget.onReaction(widget.media.id, emoji);
                              setState(() => _isExpanded = false);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                              child: Transform.scale(
                                scale: isSelected ? 1.2 : 1.0,
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 24),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
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

  @override
  void dispose() {
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
    }
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
                  child: const Center(child: Icon(Icons.error)),
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
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        if (_isPlaying) {
          _controller!.pause();
        } else {
          _controller!.play();
        }
        setState(() => _isPlaying = !_isPlaying);
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: VideoPlayer(_controller!),
          ),
          if (!_isPlaying)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(50),
              ),
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
            ),
        ],
      ),
    );
  }
}
