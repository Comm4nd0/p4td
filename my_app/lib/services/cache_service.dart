import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Lightweight local cache using Hive for stale-while-revalidate patterns.
///
/// Cached data types (safe to cache):
///   - dogs list (core, rarely changes)
///   - user profile (permissions, preferences)
///   - feed posts (last 20 for quick viewing)
///
/// NOT cached (stale data is dangerous):
///   - requests, queries, inquiries (status changes matter)
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  static const _boxName = 'p4td_cache';
  static const _feedKey = 'feed';
  static const _dogsKey = 'dogs';
  static const _profileKey = 'profile';

  Box? _box;
  bool _isInitialized = false;

  /// Open the Hive box. Call once at startup.
  Future<void> init() async {
    if (_isInitialized) return;
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    _isInitialized = true;
  }

  /// Test hook: inject an already-open box instead of [init], which needs
  /// platform channels for the documents directory.
  @visibleForTesting
  void initWithBox(Box box) {
    _box = box;
    _isInitialized = true;
  }

  // ── Generic helpers ─────────────────────────────────────────────

  Future<void> _put(String key, dynamic value) async {
    if (_box == null) return;
    await _box!.put(key, jsonEncode(value));
  }

  dynamic _get(String key) {
    if (_box == null) return null;
    final raw = _box!.get(key);
    if (raw == null) return null;
    return jsonDecode(raw as String);
  }

  // ── Dogs ────────────────────────────────────────────────────────

  /// Cache the dogs list as JSON.
  Future<void> cacheDogs(List<Map<String, dynamic>> dogsJson) =>
      _put(_dogsKey, dogsJson);

  /// Retrieve cached dogs JSON list, or null if no cache.
  List<Map<String, dynamic>>? getCachedDogs() {
    final data = _get(_dogsKey);
    if (data == null) return null;
    return (data as List).cast<Map<String, dynamic>>();
  }

  // ── Profile ─────────────────────────────────────────────────────

  Future<void> cacheProfile(Map<String, dynamic> profileJson) =>
      _put(_profileKey, profileJson);

  Map<String, dynamic>? getCachedProfile() {
    final data = _get(_profileKey);
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

  // ── Feed ────────────────────────────────────────────────────────

  /// Cache the most recent feed posts (capped at 20).
  Future<void> cacheFeed(List<Map<String, dynamic>> feedJson) =>
      _put(_feedKey, feedJson.take(20).toList());

  List<Map<String, dynamic>>? getCachedFeed() {
    final data = _get(_feedKey);
    if (data == null) return null;
    return (data as List).cast<Map<String, dynamic>>();
  }

  // ── Sort Preferences ─────────────────────────────────────────────

  static const _sortPrefPrefix = 'sort_pref_';

  /// Save the user's chosen sort option for a given screen.
  Future<void> cacheSortPreference(String screenKey, String sortOptionName) async {
    if (_box == null) return;
    await _box!.put('$_sortPrefPrefix$screenKey', sortOptionName);
  }

  /// Retrieve the saved sort option name for a screen, or null if none saved.
  String? getCachedSortPreference(String screenKey) {
    if (_box == null) return null;
    return _box!.get('$_sortPrefPrefix$screenKey') as String?;
  }

  // ── Recent reaction emojis ──────────────────────────────────────

  static const _recentReactionsKey = 'recent_reaction_emojis';
  static const _recentReactionsCap = 16;

  /// Record an emoji as the most recently used reaction (MRU order,
  /// deduplicated, capped at [_recentReactionsCap]).
  Future<void> recordRecentReactionEmoji(String emoji) async {
    final recents = getRecentReactionEmojis();
    recents.remove(emoji);
    recents.insert(0, emoji);
    await _put(_recentReactionsKey, recents.take(_recentReactionsCap).toList());
  }

  /// Recently used reaction emojis, most recent first.
  List<String> getRecentReactionEmojis() {
    final data = _get(_recentReactionsKey);
    if (data == null) return [];
    return (data as List).cast<String>();
  }

  // ── Utilities ───────────────────────────────────────────────────

  /// Clear all cached data (e.g. on logout).
  Future<void> clearAll() async {
    if (_box == null) return;
    await _box!.clear();
  }
}
