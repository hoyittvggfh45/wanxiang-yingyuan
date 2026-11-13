/// 搜索热词仓库（本地数据：上次缓存 → 打包资源）。
///
/// 打开搜索面板时确保本地数据就绪；本版本不设远程热词源，数据来自
/// 上次成功缓存（SharedPreferences）与打包资源（assets/builtin/）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/plugin_config.dart';
import '../utils/app_log.dart';

/// 按模块分组的搜索热词（ChangeNotifier，数据变化时通知 UI 重建）。
class HotSearchKeywords extends ChangeNotifier {
  HotSearchKeywords._();

  static final HotSearchKeywords instance = HotSearchKeywords._();

  /// 离线打包资源（`{模块名: [热词...]}`）。
  static const String _fallbackAsset = 'assets/builtin/hot_search_keywords.json';

  /// 上次成功拉取的热词缓存键（回退到打包旧数据之前优先用它）。
  static const String _remoteCacheKey = 'hot_search_keywords_remote_cache_v1';

  /// 上次成功拉取时间戳（毫秒）。
  static const String _lastFetchKey = 'hot_search_keywords_last_fetch_v1';

  /// 单模块热词数量上限（容错：防止异常数据撑爆面板）。
  static const int maxKeywordsPerModule = 30;

  Map<String, List<String>> _data = const <String, List<String>>{};
  bool _bootstrapped = false;

  /// 本地数据是否已就绪（就绪前 UI 可显示加载态）。
  bool get bootstrapped => _bootstrapped;

  /// 返回 [type] 模块的热词（无数据时空列表，同步返回）。
  List<String> forModule(SourceType type) =>
      _data[type.name] ?? const <String>[];

  /// 打开搜索面板时调用：确保本地数据就绪（缓存 → 打包资源）。
  Future<void> load() async {
    if (_bootstrapped) return;
    final prefs = await SharedPreferences.getInstance();
    final cached = _parsePrefsCache(prefs.getString(_remoteCacheKey));
    _data = cached ?? await _loadAssetSafely();
    _bootstrapped = true;
    AppLog.instance.i(
      '[热搜] 本地数据就绪（${cached != null ? '缓存' : '打包词'}，'
      '${_data.length} 个模块）',
    );
    notifyListeners();
  }

  /// 手动刷新入口：本版本无远程热词源，沿用本地数据（诚实空操作）。
  Future<void> refresh() async {
    AppLog.instance.i('[热搜] 无远程热词源，沿用本地数据');
  }

  /// 解析热词 JSON：`{模块名: [热词...]}`。
  ///
  /// 容错规则：非法 JSON / 非 Map 返回空表；过滤空串并按出现顺序去重；
  /// 每模块截断到 [maxKeywordsPerModule]。
  static Map<String, List<String>> parseKeywordsJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object {
      return const <String, List<String>>{};
    }
    if (decoded is! Map) return const <String, List<String>>{};
    final result = <String, List<String>>{};
    decoded.forEach((Object? key, Object? value) {
      if (key is! String || key.isEmpty || value is! List) return;
      final seen = <String>{};
      final words = <String>[];
      for (final Object? item in value) {
        if (item is! String) continue;
        final word = item.trim();
        if (word.isEmpty || !seen.add(word)) continue;
        words.add(word);
        if (words.length >= maxKeywordsPerModule) break;
      }
      if (words.isEmpty) return;
      result[key] = List<String>.unmodifiable(words);
    });
    return Map<String, List<String>>.unmodifiable(result);
  }

  /// 打包资源兜底（缺失/损坏时返回空表，UI 显示「暂无热词」）。
  Future<Map<String, List<String>>> _loadAssetSafely() async {
    try {
      final String raw = await rootBundle.loadString(_fallbackAsset);
      return parseKeywordsJson(raw);
    } on Object {
      return const <String, List<String>>{};
    }
  }

  /// 解析持久化的缓存；无/损坏返回 null（交由打包资源兜底）。
  Map<String, List<String>>? _parsePrefsCache(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parsed = parseKeywordsJson(raw);
    return parsed.isEmpty ? null : parsed;
  }
}
