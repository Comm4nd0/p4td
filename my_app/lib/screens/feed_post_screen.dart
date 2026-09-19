import 'package:flutter/material.dart';
import '../models/group_media.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/feed_item_card.dart';
import '../widgets/page_body.dart';

/// One feed post on its own page — the same card the feed shows, with its
/// reactions and comments and the box to add one — for places that hand
/// the user a single post (the client dashboard's Latest Photos) rather
/// than dropping them at the top of the whole feed.
class FeedPostScreen extends StatefulWidget {
  final GroupMedia media;
  final bool isStaff;
  final bool canAddFeedMedia;

  const FeedPostScreen({
    super.key,
    required this.media,
    this.isStaff = false,
    this.canAddFeedMedia = false,
  });

  @override
  State<FeedPostScreen> createState() => _FeedPostScreenState();
}

class _FeedPostScreenState extends State<FeedPostScreen> {
  final DataService _dataService = getIt<DataService>();
  late GroupMedia _media = widget.media;

  @override
  void initState() {
    super.initState();
    // The dashboard's copy may be minutes old; pick up comments and
    // reactions added since.
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final fresh = await _dataService.getFeedItem(_media.id);
      if (mounted) setState(() => _media = fresh);
    } catch (_) {
      // The post we were handed still shows; the next action refreshes it.
    }
  }

  Future<void> _addComment(String mediaId, String text) async {
    try {
      await _dataService.addComment(mediaId, text);
      await _refresh();
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
      final updated = await _dataService.toggleReaction(mediaId, emoji);
      if (mounted) setState(() => _media = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _delete(GroupMedia media) async {
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
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dogs = _media.taggedDogs.map((d) => d.name).join(', ');
    return Scaffold(
      appBar: AppBar(title: Text(dogs.isEmpty ? 'Post' : dogs)),
      body: PageBody(
        child: RefreshIndicator.adaptive(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: FeedItemCard(
                    key: ValueKey(_media.id),
                    media: _media,
                    isStaff: widget.isStaff,
                    canAddFeedMedia: widget.canAddFeedMedia,
                    onDelete: _delete,
                    onReaction: _toggleReaction,
                    onComment: _addComment,
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
