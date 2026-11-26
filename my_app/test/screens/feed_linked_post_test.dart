import 'package:flutter_test/flutter_test.dart';

import 'package:paws4thoughtdogs/models/group_media.dart';
import 'package:paws4thoughtdogs/screens/feed_screen.dart';

GroupMedia _post(String id) => GroupMedia(
      id: id,
      uploadedBy: '4',
      uploadedByName: 'Lily',
      mediaType: MediaType.photo,
      fileUrl: 'https://example.com/$id.jpg',
      reactions: const {},
      comments: const [],
      createdAt: DateTime(2026, 11, 23, 11, 9),
    );

void main() {
  group('withLinkedPost', () {
    final page = [_post('3183'), _post('3182'), _post('3181'), _post('3180'), _post('3179')];

    test('puts a post older than the first page at the top', () {
      final feed = withLinkedPost(page, _post('3125'));
      expect(feed.map((p) => p.id), ['3125', '3183', '3182', '3181', '3180', '3179']);
    });

    test('leaves the page alone when it already holds the post', () {
      final feed = withLinkedPost(page, _post('3181'));
      expect(feed.map((p) => p.id), ['3183', '3182', '3181', '3180', '3179']);
    });

    test('leaves the page alone when there is no post to show', () {
      expect(withLinkedPost(page, null), same(page));
    });
  });
}
