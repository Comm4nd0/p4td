import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('cache_service_test');
    Hive.init(tempDir.path);
    final box = await Hive.openBox('test_cache');
    CacheService().initWithBox(box);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() => CacheService().clearAll());

  group('recent reaction emojis', () {
    test('is empty when nothing recorded', () {
      expect(CacheService().getRecentReactionEmojis(), isEmpty);
    });

    test('returns most recent first', () async {
      await CacheService().recordRecentReactionEmoji('❤️');
      await CacheService().recordRecentReactionEmoji('🐾');
      await CacheService().recordRecentReactionEmoji('😂');
      expect(
        CacheService().getRecentReactionEmojis(),
        ['😂', '🐾', '❤️'],
      );
    });

    test('re-recording moves an emoji to the front without duplicating', () async {
      await CacheService().recordRecentReactionEmoji('❤️');
      await CacheService().recordRecentReactionEmoji('🐾');
      await CacheService().recordRecentReactionEmoji('❤️');
      expect(
        CacheService().getRecentReactionEmojis(),
        ['❤️', '🐾'],
      );
    });

    test('caps the list at 16 entries', () async {
      for (var i = 0; i < 20; i++) {
        await CacheService().recordRecentReactionEmoji('emoji_$i');
      }
      final recents = CacheService().getRecentReactionEmojis();
      expect(recents.length, 16);
      expect(recents.first, 'emoji_19');
      expect(recents.last, 'emoji_4');
    });

    test('survives a round-trip through ZWJ-sequence emojis', () async {
      await CacheService().recordRecentReactionEmoji('👨‍👩‍👧‍👦');
      expect(CacheService().getRecentReactionEmojis(), ['👨‍👩‍👧‍👦']);
    });
  });
}
