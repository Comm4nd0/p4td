import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../services/cache_service.dart';

/// Default quick-bar emojis, themed for a dog daycare audience.
const List<String> kQuickReactionEmojis = [
  '❤️', '🐾', '😂', '😍', '👍', '🔥', '🥰', '🎾',
];

/// Backend stores reactions in a 20-code-point column; RGI emojis all fit
/// but guard against pathological ZWJ chains from the full picker.
const int _maxEmojiRunes = 20;

/// Shows a bottom sheet with a one-tap quick bar (recents first) and a full
/// searchable emoji picker. Returns the chosen emoji, or null if dismissed.
Future<String?> showReactionPickerSheet(
  BuildContext context, {
  String? currentReaction,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ReactionPickerSheet(currentReaction: currentReaction),
  );
}

class ReactionPickerSheet extends StatelessWidget {
  final String? currentReaction;

  const ReactionPickerSheet({super.key, this.currentReaction});

  /// Recents first (up to 4), then defaults, deduplicated, 8 slots total.
  List<String> _quickBarEmojis() {
    final recents = CacheService()
        .getRecentReactionEmojis()
        .where((e) => e.runes.length <= _maxEmojiRunes)
        .take(4)
        .toList();
    final emojis = [...recents];
    for (final emoji in kQuickReactionEmojis) {
      if (emojis.length >= kQuickReactionEmojis.length) break;
      if (!emojis.contains(emoji)) emojis.add(emoji);
    }
    return emojis;
  }

  void _select(BuildContext context, String emoji) {
    if (emoji.runes.length > _maxEmojiRunes) return;
    Navigator.pop(context, emoji);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final sheetColor = dark ? AppColors.iosDarkCard : AppColors.iosCard;
    final height = MediaQuery.of(context).size.height * 0.6;

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _quickBarEmojis().map((emoji) {
                  final isSelected = emoji == currentReaction;
                  return InkWell(
                    onTap: () => _select(context, emoji),
                    customBorder: const CircleBorder(),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? AppColors.primary.withValues(alpha: 0.12)
                            : Colors.transparent,
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primaryLight.withValues(alpha: 0.5)
                              : Colors.transparent,
                        ),
                      ),
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    ),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) =>
                    _select(context, emoji.emoji),
                config: Config(
                  // null = let the surrounding Expanded constrain the height.
                  height: null,
                  checkPlatformCompatibility: true,
                  emojiViewConfig: EmojiViewConfig(
                    emojiSizeMax: 28,
                    backgroundColor: sheetColor,
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    // Recents are managed in CacheService and shown in the
                    // quick bar above, so hide the package's recent tab.
                    recentTabBehavior: RecentTabBehavior.NONE,
                    backgroundColor: sheetColor,
                    iconColorSelected: theme.colorScheme.primary,
                    indicatorColor: theme.colorScheme.primary,
                  ),
                  bottomActionBarConfig: BottomActionBarConfig(
                    showBackspaceButton: false,
                    backgroundColor: sheetColor,
                    buttonColor: sheetColor,
                    buttonIconColor: theme.colorScheme.primary,
                  ),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: sheetColor,
                    buttonIconColor: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
