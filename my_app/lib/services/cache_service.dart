import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// A cached value together with when it was stored, for "saved HH:mm"
/// staleness indicators. [cachedAt] is null only for entries written before
/// timestamps existed.
typedef CachedEntry<T> = ({T data, DateTime? cachedAt});

/// Lightweight local cache using Hive for stale-while-revalidate patterns.
///
/// Cached data types (safe to cache):
///   - dogs list (core, rarely changes)
///   - user profile (permissions, preferences)
///   - feed posts (last 20 for quick viewing)
///   - daily assignments per date (staff need their route offline; the UI
///     shows a "saved data" indicator so staleness is visible)
///
/// NOT cached (stale data is dangerous):
///   - requests, queries, inquiries (status changes matter)
///   - unassigned dogs and compatibility conflicts (stale data would invite
///     double-assignment)
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  static const _boxName = 'p4td_cache';
  static const _feedKey = 'feed';
  // dogs/profile moved to a timestamped envelope format; the key rename is the
  // migration (old un-enveloped keys are deleted in [init]).
  static const _dogsKey = 'dogs_v2';
  static const _profileKey = 'profile_v2';
  static const _legacyKeys = ['dogs', 'profile'];

  Box? _box;
  bool _isInitialized = false;

  static const _encryptionKeyName = 'p4td_cache_hive_key';

  /// Open the Hive box (encrypted at rest). Call once at startup.
  ///
  /// The box caches owner addresses, phone numbers, access instructions and dog
  /// medical notes (UK-GDPR personal data), so it's encrypted with a 256-bit key
  /// kept in flutter_secure_storage rather than left as plaintext on disk (F4).
  Future<void> init() async {
    if (_isInitialized) return;
    await Hive.initFlutter();
    final cipher = await _encryptionCipher();
    try {
      _box = await Hive.openBox(_boxName, encryptionCipher: cipher);
    } catch (_) {
      // A pre-existing un-encrypted (or differently-keyed) box can't be opened
      // with a cipher. This is only stale-while-revalidate cache, so drop it and
      // recreate it encrypted — the data is re-fetched from the network.
      await Hive.deleteBoxFromDisk(_boxName);
      _box = await Hive.openBox(_boxName, encryptionCipher: cipher);
    }
    for (final key in _legacyKeys) {
      await _box!.delete(key);
    }
    _isInitialized = true;
  }

  /// Build the AES cipher from a key stored in the OS secure store, generating
  /// and persisting one on first run.
  Future<HiveAesCipher> _encryptionCipher() async {
    const storage = FlutterSecureStorage();
    final existing = await storage.read(key: _encryptionKeyName);
    List<int> key;
    if (existing == null) {
      key = Hive.generateSecureKey();
      await storage.write(key: _encryptionKeyName, value: base64Encode(key));
    } else {
      key = base64Decode(existing);
    }
    return HiveAesCipher(key);
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

  /// Store [value] wrapped in a `{'v': ..., 't': <iso8601>}` envelope so reads
  /// can report when the data was cached.
  Future<void> _putEntry(String key, dynamic value) =>
      _put(key, {'v': value, 't': DateTime.now().toIso8601String()});

  /// Read an envelope written by [_putEntry]. Returns null on a cache miss.
  CachedEntry<dynamic>? _getEntry(String key) {
    final raw = _get(key);
    if (raw == null) return null;
    final map = raw as Map;
    return (
      data: map['v'],
      cachedAt: DateTime.tryParse(map['t'] as String? ?? ''),
    );
  }

  // ── Dogs ────────────────────────────────────────────────────────

  /// Cache the dogs list as JSON.
  Future<void> cacheDogs(List<Map<String, dynamic>> dogsJson) =>
      _putEntry(_dogsKey, dogsJson);

  /// Retrieve cached dogs JSON list, or null if no cache.
  List<Map<String, dynamic>>? getCachedDogs() => getCachedDogsEntry()?.data;

  /// Cached dogs with the time they were stored, or null if no cache.
  CachedEntry<List<Map<String, dynamic>>>? getCachedDogsEntry() {
    final entry = _getEntry(_dogsKey);
    if (entry == null) return null;
    return (
      data: (entry.data as List).cast<Map<String, dynamic>>(),
      cachedAt: entry.cachedAt,
    );
  }

  // ── Profile ─────────────────────────────────────────────────────

  Future<void> cacheProfile(Map<String, dynamic> profileJson) =>
      _putEntry(_profileKey, profileJson);

  Map<String, dynamic>? getCachedProfile() => getCachedProfileEntry()?.data;

  /// Cached profile with the time it was stored, or null if no cache.
  CachedEntry<Map<String, dynamic>>? getCachedProfileEntry() {
    final entry = _getEntry(_profileKey);
    if (entry == null) return null;
    return (
      data: Map<String, dynamic>.from(entry.data as Map),
      cachedAt: entry.cachedAt,
    );
  }

  // ── Daily assignments ───────────────────────────────────────────

  static const _assignmentsPrefix = 'assignments_';

  String _assignmentsKey(DateTime date) {
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$_assignmentsPrefix${date.year}-$m-$d';
  }

  /// Cache one day's assignments as raw JSON, keyed per date so staff can view
  /// their route offline. Prunes entries dated more than 2 days in the past —
  /// the offline use case is today ± 1; history is reviewed online.
  Future<void> cacheAssignments(
      DateTime date, List<Map<String, dynamic>> assignmentsJson) async {
    if (_box == null) return;
    await _putEntry(_assignmentsKey(date), assignmentsJson);
    final cutoff = _assignmentsKey(DateTime.now().subtract(const Duration(days: 2)));
    final stale = _box!.keys
        .whereType<String>()
        .where((k) => k.startsWith(_assignmentsPrefix) && k.compareTo(cutoff) < 0)
        .toList();
    for (final key in stale) {
      await _box!.delete(key);
    }
  }

  /// Cached assignments for [date] with when they were stored, or null if none.
  CachedEntry<List<Map<String, dynamic>>>? getCachedAssignments(DateTime date) {
    final entry = _getEntry(_assignmentsKey(date));
    if (entry == null) return null;
    return (
      data: (entry.data as List).cast<Map<String, dynamic>>(),
      cachedAt: entry.cachedAt,
    );
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

  // ── Day board column visibility ─────────────────────────────────

  static const _dayBoardColumnsKey = 'day_board_columns';

  /// Persist the day board's show/hide column choices:
  /// {'show_unassigned': bool, 'overrides': {'<staffId>': bool, ...}}.
  Future<void> cacheDayBoardColumns(Map<String, dynamic> prefs) =>
      _put(_dayBoardColumnsKey, prefs);

  Map<String, dynamic>? getCachedDayBoardColumns() {
    final data = _get(_dayBoardColumnsKey);
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
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

  // ── Offline prefetch bookkeeping ────────────────────────────────

  static const _lastPrefetchKey = 'last_prefetch_at';

  /// Record that an offline prefetch completed successfully just now.
  Future<void> recordPrefetchCompleted() =>
      _put(_lastPrefetchKey, DateTime.now().toIso8601String());

  /// When the last successful offline prefetch ran, or null if never.
  DateTime? getLastPrefetchAt() {
    final raw = _get(_lastPrefetchKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw as String);
  }

  // ── Utilities ───────────────────────────────────────────────────

  /// Clear all cached data (e.g. on logout).
  Future<void> clearAll() async {
    if (_box == null) return;
    await _box!.clear();
  }
}
