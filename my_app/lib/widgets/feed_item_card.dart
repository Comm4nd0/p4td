import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../models/group_media.dart';
import '../services/data_service.dart';

class FeedItemCard extends StatefulWidget {
  final GroupMedia media;
  final bool isStaff;
  final Function(GroupMedia) onDelete;
  final Function(String, String) onReaction;
  final Function(String, String) onComment;

  const FeedItemCard({
    super.key,
    required this.media,
    required this.isStaff,
    required this.onDelete,
    required this.onReaction,
    required this.onComment,
  });

  @override
  State<FeedItemCard> createState() => _FeedItemCardState();
}

class _FeedItemCardState extends State<FeedItemCard> with SingleTickerProviderStateMixin {
  bool _showAllComments = false;
  final TextEditingController _commentController = TextEditingController();
  final DataService _dataService = ApiDataService();

  @override
  void dispose() {
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
                    DateFormat('d MMM, HH:mm').format(comment.createdAt),
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
                    ),
                  ),
                  maxLines: null,
                ),
              ),
              IconButton(
                onPressed: () {
                  if (_commentController.text.trim().isNotEmpty) {
                    widget.onComment(widget.media.id, _commentController.text.trim());
                    _commentController.clear();
                    setState(() => _showAllComments = true); // Auto expand on new comment
                  }
                },
                icon: const Icon(Icons.send, color: Colors.blue),
              ),
            ],
          ),
        ),
      ],
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
              child: GestureDetector(
                onTap: _showReactionDetails,
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
            ),
          
          // Popup Reaction Interface
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PopupMenuButton<String>(
                onSelected: (emoji) => widget.onReaction(widget.media.id, emoji),
                itemBuilder: (context) => commonEmojis.map((emoji) {
                  final isSelected = widget.media.userReaction == emoji;
                  return PopupMenuItem<String>(
                    value: emoji,
                    child: Row(
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 24)),
                        if (isSelected) ...[
                           const SizedBox(width: 8),
                           const Icon(Icons.check, color: Colors.blue, size: 16),
                        ],
                      ],
                    ),
                  );
                }).toList(),
                offset: const Offset(0, -250),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
