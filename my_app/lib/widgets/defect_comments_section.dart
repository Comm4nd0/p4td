import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/comment.dart';
import '../utils/date_formats.dart';

/// A comment thread + composer for the defect detail screens, used to track a
/// defect's progress (e.g. "part ordered, awaiting delivery"). The parent owns
/// the submit call and refreshes its defect from the returned data.
class DefectCommentsSection extends StatefulWidget {
  final List<Comment> comments;
  final Future<void> Function(String text) onSubmit;

  const DefectCommentsSection({
    super.key,
    required this.comments,
    required this.onSubmit,
  });

  @override
  State<DefectCommentsSection> createState() => _DefectCommentsSectionState();
}

class _DefectCommentsSectionState extends State<DefectCommentsSection> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSubmit(text);
      if (mounted) _controller.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add comment: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final comments = widget.comments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Comments',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        if (comments.isEmpty)
          Text('No comments yet', style: TextStyle(color: Colors.grey[600]))
        else
          ...comments.map((c) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(c.userName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(width: 8),
                      Text(ukDateTime(c.createdAt.toLocal()),
                          style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                    ]),
                    const SizedBox(height: 2),
                    Text(c.text),
                  ],
                ),
              )),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Add a comment… (e.g. part ordered)',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          IconButton(
            tooltip: 'Send comment',
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Picon(PiconsDuotone.paperPlaneTilt, color: AppColors.primary),
          ),
        ]),
      ],
    );
  }
}
