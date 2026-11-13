/// 红果评论：自有评论中继客户端与评论身份。
///
/// 移植自火蚁TV Dart 侧 `comment_api.dart`（中继接口）、
/// `comment_models.dart`（评论模型）、`comment_identity.dart`（评论身份）。
/// 注意：这是 App 自有的评论中继（评论存在己方中继服务上），不是红果
/// 官方评论接口；官方评论发表/点赞在来源实现里没有对应接口，为缺项。
///
/// 中继地址不写死：[HongguoCommentApiClient] 的 baseUrl 由接线方传入
/// （中转地址内置隐藏，界面不得显示），本文件不含任何中继地址常量。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 评论。
class HongguoVideoComment {
  const HongguoVideoComment({
    required this.id,
    required this.videoKey,
    required this.text,
    required this.timeMs,
    required this.senderId,
    required this.nickname,
    required this.createdAt,
  });

  final String id;
  final String videoKey;
  final String text;
  final int timeMs;
  final String senderId;
  final String nickname;
  final int createdAt;

  factory HongguoVideoComment.fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? videoKey = json['videoKey'];
    final Object? text = json['text'];
    final Object? timeMs = json['timeMs'];
    final Object? senderId = json['senderId'];
    final Object? nickname = json['nickname'];
    final Object? createdAt = json['createdAt'];
    if (id is! String ||
        id.isEmpty ||
        videoKey is! String ||
        videoKey.isEmpty ||
        text is! String ||
        text.trim().isEmpty ||
        text.runes.length > 200 ||
        timeMs is! int ||
        timeMs < 0 ||
        senderId is! String ||
        senderId.isEmpty ||
        nickname is! String ||
        nickname.runes.length > 40 ||
        createdAt is! int ||
        createdAt <= 0) {
      throw const FormatException('评论数据无效');
    }
    return HongguoVideoComment(
      id: id,
      videoKey: videoKey,
      text: text,
      timeMs: timeMs,
      senderId: senderId,
      nickname: nickname,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'videoKey': videoKey,
        'text': text,
        'timeMs': timeMs,
        'senderId': senderId,
        'nickname': nickname,
        'createdAt': createdAt,
      };
}

/// 相对时间（刚刚 / N 分钟前 / N 小时前 / N 天前）。
String hongguoCommentRelativeTime(int createdAtMs, int nowMs) {
  final int diff = nowMs - createdAtMs;
  if (diff < 60000) return '刚刚';
  if (diff < 3600000) return '${diff ~/ 60000}分钟前';
  if (diff < 86400000) return '${diff ~/ 3600000}小时前';
  return '${diff ~/ 86400000}天前';
}

/// 评论显示名：有昵称显示昵称，否则显示“用户 + 发送者 ID 后 4 位”。
String hongguoCommentDisplayName(HongguoVideoComment comment) {
  if (comment.nickname.isNotEmpty) return comment.nickname;
  final String sender = comment.senderId;
  final String tail =
      sender.length >= 4 ? sender.substring(sender.length - 4) : sender;
  return '用户$tail';
}

/// 评论线索键：`剧 ID:集 ID`。
String hongguoCommentThreadKey(String dramaId, String episodeId) =>
    '$dramaId:$episodeId';

class HongguoCommentApiException implements Exception {
  const HongguoCommentApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 评论分页结果。
class HongguoCommentPageResult {
  const HongguoCommentPageResult(
      {required this.items, required this.nextBefore});

  final List<HongguoVideoComment> items;
  final String? nextBefore;
}

/// 评论中继客户端：baseUrl 必须由接线方传入，本文件不写死地址。
class HongguoCommentApiClient {
  HongguoCommentApiClient({HttpClient? http, required String baseUrl})
      : _http = http ?? HttpClient(),
        _baseUrl = baseUrl;

  static const Duration _timeout = Duration(seconds: 10);

  final HttpClient _http;
  final String _baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$_baseUrl$path').replace(queryParameters: query);

  Future<HongguoCommentPageResult> fetch({
    required String videoKey,
    int limit = 100,
    String? before,
  }) async {
    final Map<String, String> query = <String, String>{
      'videoKey': videoKey,
      'limit': '$limit'
    };
    if (before != null) query['before'] = before;
    final Uri uri = _uri('/comments', query);
    final HttpClientRequest request = await _http.getUrl(uri).timeout(_timeout);
    final HttpClientResponse response = await request.close().timeout(_timeout);
    final String body =
        await response.transform(utf8.decoder).join().timeout(_timeout);
    if (response.statusCode != 200) {
      throw HongguoCommentApiException('评论加载失败（${response.statusCode}）');
    }
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const HongguoCommentApiException('评论数据无效');
    }
    final Object? rows = decoded['items'];
    if (rows is! List) {
      throw const HongguoCommentApiException('评论数据无效');
    }
    final List<HongguoVideoComment> items = <HongguoVideoComment>[];
    for (final Object? row in rows) {
      if (row is Map<String, dynamic>) {
        try {
          items.add(HongguoVideoComment.fromJson(row));
        } on Object {
          // 单条坏数据跳过，不影响整页。
        }
      }
    }
    final Object? next = decoded['nextBefore'];
    return HongguoCommentPageResult(
      items: items,
      nextBefore: next is String && next.isNotEmpty ? next : null,
    );
  }

  Future<HongguoVideoComment> post({
    required String videoKey,
    required String text,
    required int timeMs,
    required String senderId,
    required String nickname,
  }) async {
    final Uri uri = _uri('/comments');
    final HttpClientRequest request =
        await _http.postUrl(uri).timeout(_timeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(<String, dynamic>{
      'videoKey': videoKey,
      'text': text,
      'timeMs': timeMs,
      'senderId': senderId,
      'nickname': nickname,
    }));
    final HttpClientResponse response = await request.close().timeout(_timeout);
    final String body =
        await response.transform(utf8.decoder).join().timeout(_timeout);
    if (response.statusCode == 429) {
      throw const HongguoCommentApiException('发得太快了，稍后再试');
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw HongguoCommentApiException('评论发送失败（${response.statusCode}）');
    }
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const HongguoCommentApiException('评论数据无效');
    }
    return HongguoVideoComment.fromJson(decoded);
  }
}

const String hongguoCommentUserIdKey = 'comment_user_id';
const String hongguoCommentNicknameKey = 'comment_nickname';

/// 生成评论用户 ID（UUID v4 样式，运行时生成）。
String generateHongguoCommentUserId(Random random) {
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final String hex =
      bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 默认评论昵称：用户 + ID 后 4 位。
String defaultHongguoCommentNickname(String userId) {
  final String tail =
      userId.length >= 4 ? userId.substring(userId.length - 4) : userId;
  return '用户$tail';
}

/// 昵称是否合法：非空且不超过 20 字。
bool validHongguoCommentNickname(String nickname) {
  final String trimmed = nickname.trim();
  return trimmed.isNotEmpty && trimmed.runes.length <= 20;
}

/// 评论身份：本机生成的用户 ID 与昵称，存在本地。
class HongguoCommentIdentity extends ChangeNotifier {
  HongguoCommentIdentity._();

  static final HongguoCommentIdentity instance = HongguoCommentIdentity._();

  String _userId = '';
  String _nickname = '';
  bool _ready = false;
  Future<void>? _pending;

  String get userId => _userId;

  String get nickname => _nickname;

  bool get ready => _ready;

  Future<void> ensureReady() {
    _pending ??= _load();
    return _pending!;
  }

  Future<void> _load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    String? userId = preferences.getString(hongguoCommentUserIdKey);
    if (userId == null || userId.isEmpty) {
      userId = generateHongguoCommentUserId(Random.secure());
      await preferences.setString(hongguoCommentUserIdKey, userId);
    }
    String? nickname = preferences.getString(hongguoCommentNicknameKey);
    if (nickname == null || nickname.isEmpty) {
      nickname = defaultHongguoCommentNickname(userId);
      await preferences.setString(hongguoCommentNicknameKey, nickname);
    }
    _userId = userId;
    _nickname = nickname;
    _ready = true;
    notifyListeners();
  }

  Future<bool> setNickname(String nickname) async {
    if (!validHongguoCommentNickname(nickname)) return false;
    await ensureReady();
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(hongguoCommentNicknameKey, nickname.trim());
    _nickname = nickname.trim();
    notifyListeners();
    return true;
  }

  @visibleForTesting
  void debugReset() {
    _userId = '';
    _nickname = '';
    _ready = false;
    _pending = null;
  }
}
