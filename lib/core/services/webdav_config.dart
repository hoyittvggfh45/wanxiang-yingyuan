/// WebDAV 配置（共享）：URL / 用户名 / 密码（安全存储）/ 自动同步偏好。
///
/// 云同步整包备份服务已按用户令删除（2026-11-13）；本文件只保留被小说功能
/// （导出上传、高亮同步、进度同步）与下载管理共用的 WebDAV 配置模型与存储，
/// 以及 PROPFIND 解析。配置键名保持不变，旧配置仍可读。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

enum SyncFrequency { manual, daily, weekly }

/// 一次同步（备份或恢复）的结果明细，用于「状态明细」展示。
class SyncStatusEntry {
  /// 时间戳（毫秒）；null 表示从未执行。
  final int? timestamp;
  /// 是否成功；null 表示从未执行。
  final bool? success;
  /// 涉及的数据条数（0 表示「无变化」或失败未统计）。
  final int itemCount;
  /// 涉及的 box 名列表（空表示全部 / 无）。
  final List<String> scope;
  /// 是否为「无变化，无需同步」。
  final bool noChanges;

  const SyncStatusEntry({
    this.timestamp,
    this.success,
    this.itemCount = 0,
    this.scope = const <String>[],
    this.noChanges = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (timestamp != null) 'timestamp': timestamp,
        if (success != null) 'success': success,
        'itemCount': itemCount,
        'scope': scope,
        'noChanges': noChanges,
      };

  factory SyncStatusEntry.fromJson(Map<String, dynamic> json) => SyncStatusEntry(
        timestamp: json['timestamp'] as int?,
        success: json['success'] as bool?,
        itemCount: (json['itemCount'] as int?) ?? 0,
        scope: (json['scope'] as List?)?.map((e) => e as String).toList() ??
            const <String>[],
        noChanges: (json['noChanges'] as bool?) ?? false,
      );
}

/// WebDAV 配置（URL/用户名/密码除外，密码用 secure storage）
class CloudSyncConfig {
  final String url;
  final String username;
  final bool autoSync;
  final SyncFrequency frequency;
  final int? lastSyncTimestamp; // null = never synced

  /// 上次备份（上传）明细。
  final SyncStatusEntry? lastUpload;

  /// 上次恢复（下载）明细。
  final SyncStatusEntry? lastRestore;

  /// 各 box（及 `__prefs__`）的内容 sha256，用于增量同步。
  final Map<String, String>? boxHashes;

  /// 小说导出完成后自动把 EPUB 产物上传到 WebDAV `wxyy/exports/`。
  /// 独立于整包备份的 autoSync（导出上传与备份节奏无关）。
  final bool autoUploadNovelExports;

  const CloudSyncConfig({
    this.url = '',
    this.username = '',
    this.autoSync = false,
    this.frequency = SyncFrequency.manual,
    this.lastSyncTimestamp,
    this.lastUpload,
    this.lastRestore,
    this.boxHashes,
    this.autoUploadNovelExports = false,
  });

  /// 下次自动同步时间戳（毫秒）；不满足自动同步条件时返回 null。
  int? get nextSyncTimestamp {
    if (!autoSync ||
        frequency == SyncFrequency.manual ||
        lastUpload?.timestamp == null) {
      return null;
    }
    final delta = frequency == SyncFrequency.daily
        ? const Duration(days: 1)
        : const Duration(days: 7);
    return lastUpload!.timestamp! + delta.inMilliseconds;
  }

  CloudSyncConfig copyWith({
    String? url,
    String? username,
    bool? autoSync,
    SyncFrequency? frequency,
    int? lastSyncTimestamp,
    SyncStatusEntry? lastUpload,
    SyncStatusEntry? lastRestore,
    Map<String, String>? boxHashes,
    bool? autoUploadNovelExports,
  }) {
    return CloudSyncConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      autoSync: autoSync ?? this.autoSync,
      frequency: frequency ?? this.frequency,
      lastSyncTimestamp: lastSyncTimestamp ?? this.lastSyncTimestamp,
      lastUpload: lastUpload ?? this.lastUpload,
      lastRestore: lastRestore ?? this.lastRestore,
      boxHashes: boxHashes ?? this.boxHashes,
      autoUploadNovelExports:
          autoUploadNovelExports ?? this.autoUploadNovelExports,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'username': username,
        'autoSync': autoSync,
        'frequency': frequency.name,
        if (lastSyncTimestamp != null)
          'lastSyncTimestamp': lastSyncTimestamp,
        if (lastUpload != null) 'lastUpload': lastUpload!.toJson(),
        if (lastRestore != null) 'lastRestore': lastRestore!.toJson(),
        if (boxHashes != null) 'boxHashes': boxHashes,
        'autoUploadNovelExports': autoUploadNovelExports,
      };

  factory CloudSyncConfig.fromJson(Map<String, dynamic> json) {
    SyncFrequency parseFrequency(String? name) {
      switch (name) {
        case 'daily':
          return SyncFrequency.daily;
        case 'weekly':
          return SyncFrequency.weekly;
        case 'manual':
        default:
          return SyncFrequency.manual;
      }
    }

    SyncStatusEntry? parseStatus(dynamic raw) =>
        raw is Map<String, dynamic> ? SyncStatusEntry.fromJson(raw) : null;

    Map<String, String>? parseHashes(dynamic raw) {
      if (raw is! Map) return null;
      return raw.map((k, v) => MapEntry(k as String, v as String));
    }

    return CloudSyncConfig(
      url: (json['url'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      autoSync: (json['autoSync'] as bool?) ?? false,
      frequency: parseFrequency(json['frequency'] as String?),
      lastSyncTimestamp: json['lastSyncTimestamp'] as int?,
      lastUpload: parseStatus(json['lastUpload']),
      lastRestore: parseStatus(json['lastRestore']),
      boxHashes: parseHashes(json['boxHashes']),
      autoUploadNovelExports:
          (json['autoUploadNovelExports'] as bool?) ?? false,
    );
  }
}

class CloudSyncConfigStore {
  static const String _prefsKey = 'cloud_sync_config_v1';
  static const String _passwordKey = 'cloud_sync_webdav_password';

  Future<CloudSyncConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const CloudSyncConfig();
    try {
      return CloudSyncConfig.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const CloudSyncConfig();
    }
  }

  Future<void> save(CloudSyncConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
  }

  Future<String?> loadPassword() async {
    const storage = FlutterSecureStorage();
    return await storage.read(key: _passwordKey);
  }

  Future<void> savePassword(String password) async {
    const storage = FlutterSecureStorage();
    await storage.write(key: _passwordKey, value: password);
  }

  Future<void> clearPassword() async {
    const storage = FlutterSecureStorage();
    await storage.delete(key: _passwordKey);
  }
}

/// 远程 WebDAV 文件项
/// 远程 WebDAV 文件项（PROPFIND 解析结果）。
class WebdavRemoteFile {
  final String name;
  final bool isCollection;

  const WebdavRemoteFile({required this.name, required this.isCollection});
}

/// 取第一个元素，空则返回 null（本文件不依赖 collection 包）。
T? _firstOrNull<T>(Iterable<T> items) => items.isEmpty ? null : items.first;

/// 解析 WebDAV PROPFIND 响应，返回远端文件列表（跳过目录自身）。
/// 注意：`package:xml` 6.x 中 `XmlElement.value` 恒为 null，元素文本必须用
/// innerText —— 误用 .value 会导致远端列表恒为空。
List<WebdavRemoteFile> parseWebdavPropfind(String body) {
  final files = <WebdavRemoteFile>[];
  if (body.isEmpty) return files;
  try {
    final doc = XmlDocument.parse(body);
    for (final response in doc.findAllElements('response', namespace: '*')) {
      final hrefElements = response.findElements('href', namespace: '*');
      final hrefElement = hrefElements.isEmpty ? null : hrefElements.first;
      if (hrefElement == null) continue;
      final href = hrefElement.innerText.trim();
      if (href.isEmpty) continue;
      final decoded = Uri.decodeFull(href);
      String name = decoded;
      if (decoded.endsWith('/')) {
        continue;
      }
      final lastSlash = decoded.lastIndexOf('/');
      if (lastSlash >= 0 && lastSlash < decoded.length - 1) {
        name = decoded.substring(lastSlash + 1);
      }
      final propstat = _firstOrNull(
          response.findElements('propstat', namespace: '*'));
      final prop = propstat == null
          ? null
          : _firstOrNull(propstat.findElements('prop', namespace: '*'));
      final resourcetype = prop == null
          ? null
          : _firstOrNull(prop.findElements('resourcetype', namespace: '*'));
      final isCollection = resourcetype != null &&
          _firstOrNull(
                  resourcetype.findElements('collection', namespace: '*')) !=
              null;
      files.add(WebdavRemoteFile(name: name, isCollection: isCollection));
    }
  } catch (_) {
    // XML 解析失败：返回空列表
  }
  return files;
}
