/// 网页爬取内一键生成 py：以本次爬取实际拿到的数据为依据生成 py 蜘蛛。
///
/// 依据：爬取页地址（取 origin 作基址）+ 本次实际拉取的页面 HTML（CMS
/// 结构探测，不再重新拉首页）+ 页面标题（作源名）+ 通用模式下已提取的
/// 链接地址（作结构佐证）。苹果 CMS / WordPress 两类接口探测仍需请求
/// 其各自接口地址（由基址派生，不是让用户重新输网址）。
///
/// 探测链（与原输入网址版一致）：① 域名精确匹配已知站（模板 id 作 hint
/// 置顶）→ ② CMS 特征逐个探（苹果 CMS → TVBox 接口 → MacCMS →
/// WordPress → Next.js）→ ③ 通用嗅探兜底（爬取已证明站点可达）。
/// 命中验证页时抛 [OneKeyVerificationException]（走现有验证流程，不绕
/// 过）；爬取数据不足（无页面内容）时诚实报错，不编假规则。
///
/// 生成只产出代码（[OneKeyCodeResult]），默认不注册；调用方按需经
/// [OneKeyPyService.registerGenerated] 注册进站点列表，或经导出通道
/// 保存/分享 py 文件。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/models/plugin_config.dart';
import '../../core/scraper/http_fetcher.dart';
import '../../core/scraper/verification_detector.dart';
import '../../core/services/source_repository.dart';
import '../../core/spider/py_spider_validator.dart';
import '../../features/sources/presentation/py_import_sheet.dart';
import 'onekey_templates.dart';

/// 生成失败（诚实错误，直接展示给用户）。
class OneKeyException implements Exception {
  OneKeyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 探测命中验证页：需用户走现有验证流程，本服务不绕过。
class OneKeyVerificationException extends OneKeyException {
  OneKeyVerificationException(String url)
    : super('该站点需要验证后才能访问：$url。请先在浏览器里完成验证，再回来生成。');
}

/// 生成出的 py 代码（未注册）。
class OneKeyCodeResult {
  const OneKeyCodeResult({
    required this.code,
    required this.fileName,
    required this.siteName,
    required this.base,
    required this.templateId,
    required this.mode,
    required this.api,
  });

  /// 生成的 py 蜘蛛源码全文。
  final String code;

  /// 建议文件名（如 `examplecom.py`）。
  final String fileName;

  /// 源名（页面标题净化后，或由基址推导）。
  final String siteName;

  /// 站点基址（爬取地址的 origin）。
  final String base;

  /// 命中的模板 id（`generic_html` 为通用嗅探兜底）。
  final String templateId;

  /// 探测结论模式（如 `apple cms json`）。
  final String mode;

  /// 命中的接口地址（无则为空）。
  final String api;
}

/// 注册结果（经 [OneKeyPyService.registerGenerated]）。
class OneKeyGenerateResult {
  const OneKeyGenerateResult({
    required this.config,
    required this.templateId,
    required this.mode,
    required this.api,
    required this.bases,
    required this.updated,
  });

  final PluginConfig config;
  final String templateId;
  final String mode;
  final String api;
  final List<String> bases;
  final bool updated;
}

class OneKeyPyService {
  OneKeyPyService({
    Future<String> Function(String url)? fetch,
    Future<String> Function()? templateText,
    OneKeyTemplateLibrary? library,
  }) : _fetch = fetch ?? _defaultFetch,
       _templateText = templateText ?? _defaultTemplateText,
       _library = library ?? OneKeyTemplateLibrary();

  static const String templateAssetPath =
      'assets/py_tools/universal_spider_template.py';

  /// 通用嗅探兜底的模板 id：未命中任一 CMS 时的生成结论，不算
  /// “认得出结构”，自动进站时不凭它建站（手动生成/导出不受限）。
  static const String genericTemplateId = 'generic_html';

  /// CMS 探测顺序（与原工具 `_generate_code` 一致）。
  static const List<String> probeOrder = <String>[
    'apple_cms_v10',
    'tvbox_api',
    'maccms_html',
    'wordpress',
    'nextjs',
  ];

  static const List<String> _applePaths = <String>[
    '/api.php/provide/vod',
    '/api.php/provide/vod/at/json',
    '/provide/vod',
    '/api/vod',
  ];

  static const List<String> _maccmsFeatures = <String>[
    '/vod/detail/',
    '/vod/play/',
    '/vod/type/',
    '/vod/search/',
    '/voddetail/',
    '/vodplay/',
    '/vodtype/',
    '/vodsearch/',
    '/index.php/vod/',
  ];

  final Future<String> Function(String url) _fetch;
  final Future<String> Function() _templateText;
  final OneKeyTemplateLibrary _library;

  static Future<String> _defaultFetch(String url) {
    return HttpFetcher.instance.getHtml(
      url,
      headers: <String, String>{'User-Agent': 'Mozilla/5.0'},
      stealth: false,
    );
  }

  static Future<String> _defaultTemplateText() =>
      rootBundle.loadString(templateAssetPath);

  /// 由地址推导默认源名（与原工具 `_safe_name` 一致：host 去 www./端口，
  /// 仅留字母数字与汉字，空则“生成源”）。
  static String safeName(String site) {
    String host;
    try {
      host = Uri.parse(site).host;
      if (host.isEmpty) host = site;
    } on Object {
      host = site;
    }
    host = host.replaceAll('www.', '');
    final String name = host
        .split(':')
        .first
        .replaceAll(RegExp(r'[^0-9A-Za-z\u4e00-\u9fa5]+'), '');
    return name.isEmpty ? '生成源' : name;
  }

  /// 页面标题净化为可安全填进模板 `SITE_NAME = "..."` 的源名：去引号、
  /// 反斜杠与控制字符、空白折叠、截断；净化后为空返回空（调用方回落
  /// 到 [safeName]）。
  static String sanitizeTitle(String? title) {
    if (title == null) return '';
    final String cleaned = title
        .replaceAll(RegExp(r'["\\]'), '')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '';
    return cleaned.length > 24 ? cleaned.substring(0, 24).trim() : cleaned;
  }

  /// Python 风格的列表字面量（供 @BASES@ 占位符）。
  static String pythonReprList(List<String> items) {
    final String inner = items.map((String s) => "'$s'").join(', ');
    return '[$inner]';
  }

  /// 由爬取数据生成 py 代码（不注册）：返回代码与探测结论；数据不足
  /// 或验证拦截时抛 [OneKeyException]。
  Future<OneKeyCodeResult> generateFromScrape({
    required String scrapeUrl,
    required String html,
    String? pageTitle,
    List<String> linkUrls = const <String>[],
    String name = '',
    void Function(String progress)? onProgress,
  }) async {
    final String base = originOf(scrapeUrl);
    if (base.isEmpty) {
      throw OneKeyException('未能从爬取地址解析出站点基址：$scrapeUrl');
    }
    if (html.trim().isEmpty) {
      throw OneKeyException(
        '本次爬取没有拿到页面内容，无法生成 py。请先在网页爬取里打开一个能正常显示的页面，再点生成。',
      );
    }
    String siteName = name.trim();
    if (siteName.isEmpty) siteName = sanitizeTitle(pageTitle);
    if (siteName.isEmpty) siteName = safeName(base);

    onProgress?.call('正在匹配已知站点模板…');
    String hint = '';
    try {
      hint = await _library.matchTemplateId(base) ?? '';
    } on Object {
      hint = '';
    }
    final List<String> order = <String>[...probeOrder];
    if (hint.isNotEmpty && order.contains(hint)) {
      order.remove(hint);
      order.insert(0, hint);
    }

    // 结构证据：本次爬取的 HTML + 已提取的链接地址（通用模式下的导航/
    // 列表链接能佐证 CMS 路径特征）。首页不再重新拉取。
    final String evidence = <String>[
      html,
      ...linkUrls,
    ].join('\n');

    String templateId = genericTemplateId;
    String foundForce = 'html';
    String foundMode = 'generic html sniffing';
    String foundApi = '';

    // 命中验证页：不绕过，转为带指引的诚实错误。
    try {
      for (final String tid in order) {
        onProgress?.call('正在探测：$tid…');
        if (tid == 'apple_cms_v10') {
          final String? api = await _probeApple(base);
          if (api != null) {
            templateId = tid;
            foundForce = 'json';
            foundMode = 'apple cms json';
            foundApi = api;
            break;
          }
        } else if (tid == 'tvbox_api') {
          final String? host = await _probeTvbox(base, evidence);
          if (host != null) {
            templateId = tid;
            foundForce = 'html';
            foundMode = 'tvbox api';
            foundApi = host;
            break;
          }
        } else if (tid == 'maccms_html') {
          if (_probeMaccms(evidence)) {
            templateId = tid;
            foundForce = 'html';
            foundMode = 'maccms html';
            break;
          }
        } else if (tid == 'wordpress') {
          if (await _probeWordpress(base)) {
            templateId = tid;
            foundForce = 'html';
            foundMode = 'wordpress';
            break;
          }
        } else if (tid == 'nextjs') {
          if (evidence.contains('/_next/static') &&
              evidence.contains('/vod/play/') &&
              evidence.contains('/detail/')) {
            templateId = tid;
            foundForce = 'nextjs';
            foundMode = 'nextjs';
            break;
          }
        }
      }
    } on VerificationRequiredException catch (e) {
      throw OneKeyVerificationException(e.url);
    }
    // 未命中任一 CMS 时走通用嗅探兜底：爬取本身已证明站点可达，
    // 不再额外发请求确认。

    onProgress?.call('正在生成 py 蜘蛛…');
    final String template = await _templateText();
    final DateTime now = DateTime.now();
    final String ts =
        '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final String code = template
        .replaceAll('@NAME@', siteName)
        .replaceAll('@SITE@', base)
        .replaceAll('@BASES@', pythonReprList(<String>[base]))
        .replaceAll('@API@', foundApi)
        .replaceAll('@FORCE@', foundForce)
        .replaceAll('@IMGPROXY@', '')
        .replaceAll('@MODE@', foundMode)
        .replaceAll('@TS@', ts);

    final PyValidation validation = validatePySource(code);
    if (!validation.ok) {
      throw OneKeyException('生成的 py 未通过校验：${validation.failureReason}');
    }

    return OneKeyCodeResult(
      code: code,
      fileName: '${safeName(base)}.py',
      siteName: siteName,
      base: base,
      templateId: templateId,
      mode: foundMode,
      api: foundApi,
    );
  }

  /// 把已生成的代码注册进站点列表（与 py 导入同一校验与存储路径）。
  Future<OneKeyGenerateResult> registerGenerated({
    required SourceRepository repo,
    required OneKeyCodeResult generated,
  }) async {
    final PyValidation validation = validatePySource(generated.code);
    if (!validation.ok) {
      throw OneKeyException('生成的 py 未通过校验：${validation.failureReason}');
    }
    final PyImportOutcome outcome = await PyImporter.importCode(
      repo: repo,
      fileName: generated.fileName,
      code: generated.code,
    );
    if (!outcome.success || outcome.sourceId == null) {
      throw OneKeyException('注册失败：${outcome.reason ?? '未知原因'}');
    }
    final PluginConfig? config = repo.getById(outcome.sourceId!);
    if (config == null) {
      throw OneKeyException('注册后未找到源记录：${outcome.sourceId}');
    }
    // 备注追加探测结论（模板 id + 模式 + 接口）。
    final PluginConfig noted = config.copyWith(
      note:
          '${validation.remark}；网页爬取一键生成：${generated.templateId}/${generated.mode}'
          '${generated.api.isEmpty ? '' : '，接口 ${generated.api}'}',
    );
    repo.replaceSource(noted);
    return OneKeyGenerateResult(
      config: noted,
      templateId: generated.templateId,
      mode: generated.mode,
      api: generated.api,
      bases: <String>[generated.base],
      updated: outcome.updated ?? false,
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 取地址的 origin（scheme + host + 端口），无 host 返回空。
  /// 生成与去重查找共用同一推导，勿各自另写。
  static String originOf(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return '';
    final String scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
    final String port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://${uri.host}$port';
  }

  Future<String?> _probeApple(String base) async {
    for (final String path in _applePaths) {
      final String url = base + path;
      final String probeUrl = '$url${url.contains('?') ? '&' : '?'}ac=list';
      try {
        final String body = await _fetch(probeUrl)
            .timeout(const Duration(seconds: 8));
        final Object? decoded = jsonDecode(body.replaceAll('\uFEFF', ''));
        if (decoded is Map<String, dynamic>) {
          final Object? list = decoded['list'];
          if (list is List && list.isNotEmpty) return url;
          if (list is Map && list.isNotEmpty) return url;
        }
      } on VerificationRequiredException {
        rethrow;
      } on Object {
        continue;
      }
    }
    return null;
  }

  Future<String?> _probeTvbox(String base, String evidence) async {
    final List<String> hosts = <String>[];
    final RegExp hostRe = RegExp(
      r'https?://([A-Za-z0-9.\-]+)(?::\d+)?/api/tvbox/',
    );
    for (final RegExpMatch m in hostRe.allMatches(evidence)) {
      final String h = m.group(1)!;
      if (!hosts.contains(h)) hosts.add(h);
    }
    final String baseHost = Uri.tryParse(base)?.host ?? '';
    if (baseHost.isNotEmpty && !hosts.contains(baseHost)) {
      hosts.add(baseHost);
    }
    for (final String host in hosts) {
      try {
        final String body = await _fetch('https://$host/api/tvbox/home?nav=1')
            .timeout(const Duration(seconds: 8));
        final Object? decoded = jsonDecode(body.replaceAll('\uFEFF', ''));
        if (decoded is Map<String, dynamic>) {
          final Object? nav = decoded['nav'];
          final Object? list = decoded['list'];
          final Object? data = decoded['data'];
          if (_truthy(nav) || _truthy(list) || _truthy(data)) {
            return 'https://$host';
          }
        }
      } on VerificationRequiredException {
        rethrow;
      } on Object {
        continue;
      }
    }
    return null;
  }

  static bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    if (v is String) return v.isNotEmpty;
    return true;
  }

  static bool _probeMaccms(String evidence) {
    return _maccmsFeatures.any(evidence.contains);
  }

  Future<bool> _probeWordpress(String base) async {
    try {
      final String body = await _fetch('$base/wp-json/wp/v2/')
          .timeout(const Duration(seconds: 8));
      final Object? decoded = jsonDecode(body.replaceAll('\uFEFF', ''));
      if (decoded is Map<String, dynamic>) {
        return decoded.containsKey('routes') ||
            decoded.containsKey('name') ||
            decoded.containsKey('namespaces');
      }
    } on VerificationRequiredException {
      rethrow;
    } on Object {
      return false;
    }
    return false;
  }
}
