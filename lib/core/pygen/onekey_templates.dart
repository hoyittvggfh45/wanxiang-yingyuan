/// 一键写 PY 模板库：域名精确匹配（改写自火蚁聚合 OneKeyPyService）。
///
/// 模板库 asset `assets/onekey_templates.json`（110 条）。每条模板的
/// `detection.probe`（`"GET https://host/..."` 形式）抠出 host 建
/// 域名 → 模板 id 表；匹配按 host、去 `www.`、加 `www.` 三档。
library;

import 'dart:convert';

import 'package:flutter/services.dart';

/// 由模板列表建域名 → 模板 id 表（纯函数，可单测）。
Map<String, String> buildDomainTemplateMap(
  List<Map<String, dynamic>> templates,
) {
  final Map<String, String> map = <String, String>{};
  final RegExp hostRe = RegExp(r'https?://([^/{}\s:]+)');
  for (final Map<String, dynamic> template in templates) {
    final String id = template['id'] as String? ?? '';
    if (id.isEmpty) continue;
    final Object? detection = template['detection'];
    if (detection is! Map<String, dynamic>) continue;
    final Object? probes = detection['probe'];
    if (probes is! List) continue;
    for (final Object? probe in probes) {
      if (probe is! String || probe.contains('{')) continue;
      final RegExpMatch? m = hostRe.firstMatch(probe);
      if (m == null) continue;
      map.putIfAbsent(m.group(1)!, () => id);
    }
  }
  return map;
}

/// 按域名匹配模板 id：host → 去 www. → 加 www. 三档（纯函数，可单测）。
String? matchDomainTemplate(String url, Map<String, String> domainMap) {
  final Uri? uri = Uri.tryParse(url);
  String host = uri?.host ?? '';
  if (host.isEmpty) {
    host = url.split('/').first.split(':').first;
  }
  if (host.isEmpty) return null;
  if (domainMap.containsKey(host)) return domainMap[host];
  if (host.startsWith('www.')) {
    final String bare = host.substring(4);
    if (domainMap.containsKey(bare)) return domainMap[bare];
  } else {
    final String www = 'www.$host';
    if (domainMap.containsKey(www)) return domainMap[www];
  }
  return null;
}

/// 模板库加载器（asset）。
class OneKeyTemplateLibrary {
  static const String assetPath = 'assets/onekey_templates.json';

  List<Map<String, dynamic>>? _templates;
  Map<String, String>? _domainMap;

  /// 模板条数（加载后可用）。
  int get templateCount => _templates?.length ?? 0;

  Future<void> ensureLoaded() async {
    if (_templates != null) return;
    final String text = await rootBundle.loadString(assetPath);
    final Object? decoded = jsonDecode(text);
    final List<dynamic> list = decoded is Map<String, dynamic>
        ? (decoded['templates'] as List? ?? const <dynamic>[])
        : const <dynamic>[];
    _templates = list.whereType<Map<String, dynamic>>().toList();
    _domainMap = buildDomainTemplateMap(_templates!);
  }

  /// 域名精确匹配到的模板 id（未命中为 null）。
  Future<String?> matchTemplateId(String url) async {
    await ensureLoaded();
    return matchDomainTemplate(url, _domainMap!);
  }
}
