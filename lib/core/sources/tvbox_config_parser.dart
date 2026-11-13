/// TVBox / 猫源（CatVod）配置解析：纯函数，可单元测试，无 IO。
///
/// 输入一份 TVBox JSON 配置文本，输出站点草稿与失败原因：
/// - 顶层 `sites` 数组，每项 `key` / `name` / `type` / `api` / `ext`；
/// - 顶层 `jar`（TVBox）或 `spider`（猫源）字段给出 jar 地址；
/// - `type` 0/1 走采集（builtin + baseUrl，路由写法与
///   `collect_api_import_screen.dart` 的 `_buildConfig` 一致）；
/// - `type` 3 且 api 以 `csp_` 开头（或 Java 全类名）走 jar 蜘蛛；
/// - `type` 3 且 api 指向 `.py` 走 py 蜘蛛（下载与校验见
///   `tvbox_importer.dart`，本文件只做形态判定，不下载）。
///
/// 不支持的形态不硬撑：逐条记进失败原因或 [TvboxParseResult.unsupportedSections]，
/// 调用方如实展示。蜘蛛源与采集源均不声明 `ageRating`（TVBox 格式没有源自带
/// 的分级信息），年龄门沿用导入流程现有的 [SourceRepository.isAgeBlocked]。
library;

import 'dart:convert';

import '../models/plugin_config.dart';

/// TVBox 站点形态。
enum TvboxSiteKind {
  /// 采集源（type 0/1）：builtin 解析器 + MacCMS 路由。
  collect,

  /// jar 蜘蛛源（type 3，api 为 `csp_...` 或 Java 全类名）。
  jar,

  /// py 蜘蛛源（type 3，api 指向 `.py` 文件地址）。
  py,

  /// 不支持的形态（原因见 [TvboxSiteDraft.failureReason]）。
  unsupported,
}

/// 一条 TVBox 站点记录的解析结果（草稿）。
class TvboxSiteDraft {
  const TvboxSiteDraft({
    required this.key,
    required this.name,
    required this.siteType,
    required this.api,
    required this.ext,
    required this.kind,
    required this.flavor,
    this.failureReason,
  });

  /// 站点 key（用作源 id）。
  final String key;

  /// 显示名（`name` 为空时回退为 [key]）。
  final String name;

  /// TVBox type（0/1/3 等）。
  final int siteType;

  /// 原始 api 字符串（采集接口地址 / `csp_...` / `.py` 地址）。
  final String api;

  /// 原始 ext（字符串、对象、数字等均可；jar 源序列化后传给引擎）。
  final dynamic ext;

  /// 判定出的形态。
  final TvboxSiteKind kind;

  /// 配置风味：`tvbox` 或 `catvod`（顶层含 `spider` 字段时）。
  final String flavor;

  /// [kind] 为 [TvboxSiteKind.unsupported] 时的失败原因。
  final String? failureReason;
}

/// 一条无法导入的站点记录（逐条报原因，不编记录）。
class TvboxSiteFailure {
  const TvboxSiteFailure({
    required this.key,
    required this.name,
    required this.reason,
  });

  final String key;
  final String name;
  final String reason;
}

/// TVBox / 猫源配置的解析结果。
class TvboxParseResult {
  const TvboxParseResult({
    required this.isRecognized,
    required this.flavor,
    required this.jarReference,
    required this.drafts,
    required this.entryFailures,
    required this.unsupportedSections,
  });

  /// 是否识别为 TVBox / 猫源配置（顶层对象含 `sites` 键）。
  final bool isRecognized;

  /// 配置风味：`tvbox` 或 `catvod`。
  final String flavor;

  /// 顶层 `jar` / `spider` 字段的原始值（jar 地址，可能是网址）。
  final String? jarReference;

  /// 全部站点草稿（含 [TvboxSiteKind.unsupported] 的条目）。
  final List<TvboxSiteDraft> drafts;

  /// 无法成条目的失败（非对象条目、缺 key、重复 key、sites 非数组等）。
  final List<TvboxSiteFailure> entryFailures;

  /// 不支持的顶层段说明（如 parses / rules / lives），逐条列出。
  final List<String> unsupportedSections;

  /// 全部失败原因：[entryFailures] + 不支持形态的草稿。
  List<TvboxSiteFailure> get failures => <TvboxSiteFailure>[
        ...entryFailures,
        for (final d in drafts)
          if (d.kind == TvboxSiteKind.unsupported)
            TvboxSiteFailure(
              key: d.key,
              name: d.name,
              reason: d.failureReason ?? '不支持的站点形态',
            ),
      ];
}

/// 不支持的顶层段：键 → 中文说明。出现时记进 [TvboxParseResult.unsupportedSections]。
const Map<String, String> _unsupportedSectionLabels = <String, String>{
  'parses': '解析接口',
  'rules': '嗅探/替换规则',
  'lives': '直播源',
  'live': '直播源',
  'flags': '播放标识',
  'ijk': '播放器配置',
  'ads': '广告配置',
  'doh': 'DOH 配置',
  'wallpaper': '壁纸配置',
};

/// Java 全类名形态（如 `com.github.catvod.spider.Xxx`）：原生侧
/// `SpiderBridge.classNameFor` 认带点的 api，本解析器同样按 jar 源处理。
final RegExp _javaClassNamePattern =
    RegExp(r'^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)+$');

/// 解析一份 TVBox / 猫源配置文本（纯函数，不做任何 IO）。
///
/// 非 TVBox 文本（坏 JSON、非对象、顶层无 `sites` 键）返回
/// `isRecognized` 为 false 的结果，调用方继续走原有解析流程。
TvboxParseResult parseTvboxConfig(String text) {
  const unrecognized = TvboxParseResult(
    isRecognized: false,
    flavor: 'tvbox',
    jarReference: null,
    drafts: <TvboxSiteDraft>[],
    entryFailures: <TvboxSiteFailure>[],
    unsupportedSections: <String>[],
  );
  final String trimmed = text.trim();
  // 去 BOM：部分导出的配置文件带 UTF-8 BOM，jsonDecode 会因此失败。
  final String clean =
      trimmed.startsWith('\uFEFF') ? trimmed.substring(1) : trimmed;
  if (clean.isEmpty) return unrecognized;
  dynamic decoded;
  try {
    decoded = jsonDecode(clean);
  } on Object {
    return unrecognized;
  }
  if (decoded is! Map) return unrecognized;
  final Map<String, dynamic> root = Map<String, dynamic>.from(decoded);
  if (!root.containsKey('sites')) return unrecognized;

  final String flavor =
      _nonEmptyString(root['spider']) != null ? 'catvod' : 'tvbox';
  final String? jarReference =
      _nonEmptyString(root['jar']) ?? _nonEmptyString(root['spider']);

  final List<String> unsupportedSections = <String>[];
  for (final entry in _unsupportedSectionLabels.entries) {
    final dynamic value = root[entry.key];
    if (value == null) continue;
    if (value is List) {
      unsupportedSections.add(
        '${entry.key}（${entry.value}，共 ${value.length} 项）未导入：不在站点导入范围内',
      );
    } else {
      unsupportedSections.add(
        '${entry.key}（${entry.value}）未导入：不在站点导入范围内',
      );
    }
  }

  final List<TvboxSiteDraft> drafts = <TvboxSiteDraft>[];
  final List<TvboxSiteFailure> entryFailures = <TvboxSiteFailure>[];
  final dynamic sitesRaw = root['sites'];
  if (sitesRaw is! List) {
    entryFailures.add(const TvboxSiteFailure(
      key: '',
      name: '',
      reason: 'sites 不是数组，无法解析站点列表',
    ));
  } else if (sitesRaw.isEmpty) {
    entryFailures.add(const TvboxSiteFailure(
      key: '',
      name: '',
      reason: '配置的 sites 数组为空，没有可导入的站点',
    ));
  } else {
    final Set<String> seenKeys = <String>{};
    for (final dynamic item in sitesRaw) {
      if (item is! Map) {
        entryFailures.add(const TvboxSiteFailure(
          key: '',
          name: '',
          reason: 'sites 里有一条不是对象，已跳过',
        ));
        continue;
      }
      final Map<String, dynamic> site = Map<String, dynamic>.from(item);
      final String key = (site['key']?.toString() ?? '').trim();
      final String name = (site['name']?.toString() ?? '').trim();
      if (key.isEmpty) {
        entryFailures.add(TvboxSiteFailure(
          key: '',
          name: name,
          reason: '缺少 key，无法生成源 id，已跳过',
        ));
        continue;
      }
      if (!seenKeys.add(key)) {
        entryFailures.add(TvboxSiteFailure(
          key: key,
          name: name.isEmpty ? key : name,
          reason: 'key 与前面的站点重复，已跳过',
        ));
        continue;
      }
      drafts.add(_classifySite(site, key, name.isEmpty ? key : name, flavor));
    }
  }

  return TvboxParseResult(
    isRecognized: true,
    flavor: flavor,
    jarReference: jarReference,
    drafts: drafts,
    entryFailures: entryFailures,
    unsupportedSections: unsupportedSections,
  );
}

TvboxSiteDraft _classifySite(
  Map<String, dynamic> site,
  String key,
  String name,
  String flavor,
) {
  final int? siteType = _coerceSiteType(site['type']);
  final String api = (site['api']?.toString() ?? '').trim();
  final dynamic ext = site['ext'];
  TvboxSiteDraft unsupported(String reason) => TvboxSiteDraft(
        key: key,
        name: name,
        siteType: siteType ?? -1,
        api: api,
        ext: ext,
        kind: TvboxSiteKind.unsupported,
        flavor: flavor,
        failureReason: reason,
      );
  if (siteType == null) {
    return unsupported('type 缺失或无法识别，无法判定站点形态');
  }
  if (siteType == 0 || siteType == 1) {
    final Uri? uri = Uri.tryParse(api);
    if (api.isEmpty ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return unsupported('采集接口地址无效（须为 http/https 地址）：$api');
    }
    return TvboxSiteDraft(
      key: key,
      name: name,
      siteType: siteType,
      api: api,
      ext: ext,
      kind: TvboxSiteKind.collect,
      flavor: flavor,
    );
  }
  if (siteType == 3) {
    if (api.isEmpty) {
      return unsupported('缺少 api，无法判定蜘蛛形态');
    }
    if (api.startsWith('csp_') || _javaClassNamePattern.hasMatch(api)) {
      return TvboxSiteDraft(
        key: key,
        name: name,
        siteType: siteType,
        api: api,
        ext: ext,
        kind: TvboxSiteKind.jar,
        flavor: flavor,
      );
    }
    final String pathPart = api.split('?').first.split('#').first.toLowerCase();
    if (pathPart.endsWith('.py')) {
      return TvboxSiteDraft(
        key: key,
        name: name,
        siteType: siteType,
        api: api,
        ext: ext,
        kind: TvboxSiteKind.py,
        flavor: flavor,
      );
    }
    if (pathPart.endsWith('.js')) {
      return unsupported('JS 蜘蛛（.js）暂不支持：$api');
    }
    return unsupported('api 形态不明（非 csp_、非 .py、非 Java 类名）：$api');
  }
  return unsupported('type $siteType 暂不支持');
}

int? _coerceSiteType(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

String? _nonEmptyString(dynamic raw) {
  if (raw is! String) return null;
  final String value = raw.trim();
  return value.isEmpty ? null : value;
}

/// 把 TVBox 的 ext 序列化为引擎用的字符串：字符串原样、对象/数组转 JSON、其余转字符串。
String tvboxExtToString(dynamic ext) {
  if (ext == null) return '';
  if (ext is String) return ext;
  if (ext is Map || ext is List) return jsonEncode(ext);
  return ext.toString();
}

/// 按基准地址解析一条 TVBox 引用（jar 地址 / py 地址）：
/// 绝对地址（带 scheme）原样返回；相对地址有基准时拼成绝对地址；相对地址无基准时返回 null。
String? resolveTvboxReference(String raw, String? baseUri) {
  final String ref = raw.trim();
  if (ref.isEmpty) return null;
  try {
    final Uri? uri = Uri.tryParse(ref);
    if (uri != null && uri.hasScheme) return ref;
    if (ref.startsWith('/')) return ref;
    if (baseUri == null || baseUri.trim().isEmpty) return null;
    final Uri? base = Uri.tryParse(baseUri.trim());
    if (base == null || !base.hasScheme) return null;
    return base.resolve(ref).toString();
  } on Object {
    return null;
  }
}

/// 由采集草稿生成 [PluginConfig]：路由写法与
/// `collect_api_import_screen.dart` 的 `_buildConfig` 一致（baseUrl 取 api 的
/// origin，latest/search/detail/episodes 四条 MacCMS 路由，动态分类）。
///
/// 局限（与 `_buildConfig` 相同）：只认标准 MacCMS 路径
/// `/api.php/provide/vod/`，api 上非标准路径的采集接口按此路由可能取不到数；
/// type 0（XML）与 type 1（JSON）映射相同，走同一条 JSON 解析管线。
PluginConfig buildCollectConfig(TvboxSiteDraft draft) {
  if (draft.kind != TvboxSiteKind.collect) {
    throw ArgumentError('buildCollectConfig 只接受采集草稿：${draft.key}');
  }
  final Uri uri = Uri.parse(draft.api);
  final String baseUrl = uri.origin;
  final String label = draft.flavor == 'catvod' ? '猫源' : 'TVBox';
  return PluginConfig(
    id: draft.key,
    name: draft.name,
    type: SourceType.animeSource,
    site: SiteConfig(domain: uri.host, baseUrl: baseUrl),
    parser: const ParserConfig(type: 'builtin'),
    routes: <String, RouteConfig>{
      'latest':
          RouteConfig(url: '$baseUrl/api.php/provide/vod/?ac=list&pg={page}'),
      'search': RouteConfig(
          url: '$baseUrl/api.php/provide/vod/?ac=list&wd={keyword}'),
      'detail':
          RouteConfig(url: '$baseUrl/api.php/provide/vod/?ac=detail&ids={id}'),
      'episodes':
          RouteConfig(url: '$baseUrl/api.php/provide/vod/?ac=detail&ids={id}'),
    },
    category: const CategoryConfig(dynamicCategories: true),
    note: '$label采集源（type ${draft.siteType}）',
  );
}

/// 由 jar 草稿生成 [PluginConfig]：[jarAsset] 是已解析好的 jar 引用
/// （包内资源路径 `assets/...`、本地文件 `file:...` 或绝对路径），
/// 与原生侧 `SpiderBridge.resolveJarFile` 的约定一致。
PluginConfig buildJarConfig(
  TvboxSiteDraft draft, {
  required String jarAsset,
}) {
  if (draft.kind != TvboxSiteKind.jar) {
    throw ArgumentError('buildJarConfig 只接受 jar 草稿：${draft.key}');
  }
  final String label = draft.flavor == 'catvod' ? '猫源' : 'TVBox';
  return PluginConfig(
    id: draft.key,
    name: draft.name,
    type: SourceType.animeSource,
    site: const SiteConfig(domain: '', baseUrl: ''),
    parser: const ParserConfig(type: 'jar'),
    spiderEngine: SpiderEngineConfig(
      kind: 'jar',
      asset: jarAsset,
      api: draft.api,
      ext: tvboxExtToString(draft.ext),
    ),
    note: '$label jar 蜘蛛源',
  );
}

/// 由解析结果生成可直接注册的配置：采集源全部生成；jar 源仅在给了
/// [jarAsset] 时生成（jar 地址为网址时须先下载，见 `tvbox_importer.dart`）；
/// py 草稿与不支持的草稿不在此列（py 须下载源码并校验后走待确认项）。
List<PluginConfig> buildReadyConfigs(
  TvboxParseResult result, {
  String? jarAsset,
}) {
  final List<PluginConfig> out = <PluginConfig>[];
  for (final TvboxSiteDraft draft in result.drafts) {
    if (draft.kind == TvboxSiteKind.collect) {
      out.add(buildCollectConfig(draft));
    } else if (draft.kind == TvboxSiteKind.jar &&
        jarAsset != null &&
        jarAsset.isNotEmpty) {
      out.add(buildJarConfig(draft, jarAsset: jarAsset));
    }
  }
  return out;
}
