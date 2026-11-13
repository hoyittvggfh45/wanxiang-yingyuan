/// 红果收藏 / 历史续播 / 预约记录：本机记录与账号记录分开存。
///
/// 来源：火蚁TV Dart 侧 `follow_state.dart`（追剧状态：想看/在看/已看、
/// 已读集数、新季提醒）与本地存储做法；Go 核无云端同步接口，因此云端
/// 同步为缺项（见回报），本文件只做本地两套存储，绝不冒充已同步。
///
/// 两套存储键名前缀不同，永不混写：
/// - 本机：`hongguoLocal:<kind>`，未登录也能用，换账号不受影响；
/// - 账号：`hongguoAccount:<userId>:<kind>`，仅登录后读写，退出登录后
///   不再读取（数据保留在原账号名下，下次登录同一账号恢复）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'hongguo_account.dart';

/// 收藏记录。
class HongguoFavoriteRecord {
  const HongguoFavoriteRecord({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.updatedAt = 0,
  });

  final String seriesId;
  final String title;
  final String cover;
  final int updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'seriesId': seriesId,
        'title': title,
        'cover': cover,
        'updatedAt': updatedAt,
      };

  factory HongguoFavoriteRecord.fromJson(Map<String, dynamic> json) =>
      HongguoFavoriteRecord(
        seriesId: json['seriesId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        updatedAt: json['updatedAt'] as int? ?? 0,
      );
}

/// 历史续播记录：播到哪集、哪一秒。
class HongguoProgressRecord {
  const HongguoProgressRecord({
    required this.seriesId,
    required this.title,
    required this.episodeIndex,
    required this.positionMs,
    required this.durationMs,
    this.cover = '',
    this.updatedAt = 0,
  });

  final String seriesId;
  final String title;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final String cover;
  final int updatedAt;

  /// 是否播完（剩余不足 5 秒视为播完）。
  bool get finished => durationMs > 0 && durationMs - positionMs < 5000;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'seriesId': seriesId,
        'title': title,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'cover': cover,
        'updatedAt': updatedAt,
      };

  factory HongguoProgressRecord.fromJson(Map<String, dynamic> json) =>
      HongguoProgressRecord(
        seriesId: json['seriesId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        episodeIndex: json['episodeIndex'] as int? ?? 0,
        positionMs: json['positionMs'] as int? ?? 0,
        durationMs: json['durationMs'] as int? ?? 0,
        cover: json['cover'] as String? ?? '',
        updatedAt: json['updatedAt'] as int? ?? 0,
      );
}

/// 预约记录：想看/预约的剧（对应 FollowStatus.planned 的“想看”）。
class HongguoReservationRecord {
  const HongguoReservationRecord({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.updatedAt = 0,
  });

  final String seriesId;
  final String title;
  final String cover;
  final int updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'seriesId': seriesId,
        'title': title,
        'cover': cover,
        'updatedAt': updatedAt,
      };

  factory HongguoReservationRecord.fromJson(Map<String, dynamic> json) =>
      HongguoReservationRecord(
        seriesId: json['seriesId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        updatedAt: json['updatedAt'] as int? ?? 0,
      );
}

/// 单套记录存储（本机或某一账号），键名由调用方按前缀构造。
class HongguoRecordStore {
  HongguoRecordStore(this._keyPrefix);

  final String _keyPrefix;

  String get _favoritesKey => '$_keyPrefix:favorites';
  String get _progressKey => '$_keyPrefix:progress';
  String get _reservationsKey => '$_keyPrefix:reservations';

  Future<List<Map<String, dynamic>>> _readList(String key) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? raw = preferences.getString(key);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
    } on Object {
      // 损坏的记录忽略，视为空。
    }
    return <Map<String, dynamic>>[];
  }

  Future<void> _writeList(String key, List<Map<String, dynamic>> items) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, jsonEncode(items));
  }

  Future<List<HongguoFavoriteRecord>> favorites() async {
    final List<Map<String, dynamic>> rows = await _readList(_favoritesKey);
    return rows
        .map(HongguoFavoriteRecord.fromJson)
        .where((HongguoFavoriteRecord record) => record.seriesId.isNotEmpty)
        .toList();
  }

  Future<void> addFavorite(HongguoFavoriteRecord record) async {
    final List<HongguoFavoriteRecord> current = await favorites();
    current.removeWhere(
        (HongguoFavoriteRecord item) => item.seriesId == record.seriesId);
    current.insert(0, record);
    await _writeList(_favoritesKey,
        current.map((HongguoFavoriteRecord item) => item.toJson()).toList());
  }

  Future<void> removeFavorite(String seriesId) async {
    final List<HongguoFavoriteRecord> current = await favorites();
    current
        .removeWhere((HongguoFavoriteRecord item) => item.seriesId == seriesId);
    await _writeList(_favoritesKey,
        current.map((HongguoFavoriteRecord item) => item.toJson()).toList());
  }

  Future<List<HongguoProgressRecord>> progress() async {
    final List<Map<String, dynamic>> rows = await _readList(_progressKey);
    return rows
        .map(HongguoProgressRecord.fromJson)
        .where((HongguoProgressRecord record) => record.seriesId.isNotEmpty)
        .toList();
  }

  Future<void> saveProgress(HongguoProgressRecord record) async {
    final List<HongguoProgressRecord> current = await progress();
    current.removeWhere(
        (HongguoProgressRecord item) => item.seriesId == record.seriesId);
    current.insert(0, record);
    if (current.length > 200) current.removeRange(200, current.length);
    await _writeList(_progressKey,
        current.map((HongguoProgressRecord item) => item.toJson()).toList());
  }

  Future<HongguoProgressRecord?> progressFor(String seriesId) async {
    final List<HongguoProgressRecord> current = await progress();
    for (final HongguoProgressRecord record in current) {
      if (record.seriesId == seriesId) return record;
    }
    return null;
  }

  Future<List<HongguoReservationRecord>> reservations() async {
    final List<Map<String, dynamic>> rows = await _readList(_reservationsKey);
    return rows
        .map(HongguoReservationRecord.fromJson)
        .where((HongguoReservationRecord record) => record.seriesId.isNotEmpty)
        .toList();
  }

  Future<void> addReservation(HongguoReservationRecord record) async {
    final List<HongguoReservationRecord> current = await reservations();
    current.removeWhere(
        (HongguoReservationRecord item) => item.seriesId == record.seriesId);
    current.insert(0, record);
    await _writeList(_reservationsKey,
        current.map((HongguoReservationRecord item) => item.toJson()).toList());
  }

  Future<void> removeReservation(String seriesId) async {
    final List<HongguoReservationRecord> current = await reservations();
    current.removeWhere(
        (HongguoReservationRecord item) => item.seriesId == seriesId);
    await _writeList(_reservationsKey,
        current.map((HongguoReservationRecord item) => item.toJson()).toList());
  }
}

/// 本机记录存储：键名前缀 `hongguoLocal`。
HongguoRecordStore hongguoLocalRecords() => HongguoRecordStore('hongguoLocal');

/// 账号记录存储：键名前缀 `hongguoAccount:<userId>`；未登录返回 null。
HongguoRecordStore? hongguoAccountRecords([HongguoAccount? account]) {
  final HongguoAccount? current = account ?? hongguoAccountNotifier.value;
  if (current == null || !current.loggedIn) return null;
  return HongguoRecordStore('hongguoAccount:${current.userId}');
}
