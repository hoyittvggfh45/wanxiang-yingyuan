/// 手动新建空白源：纯逻辑（校验 + 构造），不依赖界面。
///
/// 与导入同一套校验口径：构造出的 [PluginConfig] 必须通过
/// [PluginConfig.validate]（导入解析入口 `_tryParseMapWithService` 也是这道
/// 关），否则不返回配置、调用方不得入库。
///
/// 默认字段取合理空值，不编假规则、不编假地址：
/// - 站名、地址由用户填写；地址必填且须是合法 http(s) URL 形态；
/// - 解析器取 `builtin`、选择器/分类/首页板块全部留空，用户在编辑页补；
/// - 唯一例外：媒体（animeSource）源按 [PluginConfig.validate] 必须有
///   `latest` 路由，否则连编辑页保存都过不了校验。空白源的 `latest` 路由
///   直接指向用户填写的站点地址本身（不拼任何路径、不编接口），选择器为
///   空，浏览时取不到条目是诚实的空结果；真实列表接口由用户在编辑页改。
library;

import '../../core/models/plugin_config.dart';

/// 手动建源的结果：成功带 [config]，失败带中文 [errors] 且 [config] 为空。
class ManualSourceResult {
  final PluginConfig? config;
  final List<String> errors;

  const ManualSourceResult._(this.config, this.errors);

  factory ManualSourceResult.ok(PluginConfig config) =>
      ManualSourceResult._(config, const <String>[]);

  factory ManualSourceResult.invalid(List<String> errors) =>
      ManualSourceResult._(null, List<String>.unmodifiable(errors));

  bool get isValid => config != null && errors.isEmpty;
}

/// 地址是否可作源站地址：绝对 URL、http/https、带 host、无空白字符。
bool isValidManualSourceUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.isAbsolute) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  return true;
}

/// 地址归一化：去首尾空白、去末尾多余 `/`（`https://host/` → `https://host`）。
/// 调用前须已通过 [isValidManualSourceUrl]。
String normalizeManualSourceUrl(String value) {
  var trimmed = value.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

/// 由地址派生源 id：`manual_<host>`（host 中的非字母数字转 `_`），
/// 与 [existingIds] 冲突时追加 `_2`、`_3`……保证不覆盖已有源。
/// 调用前须已通过 [isValidManualSourceUrl]。
String manualSourceIdFor(String baseUrl, Set<String> existingIds) {
  final host = Uri.parse(baseUrl).host.toLowerCase();
  var slug = host.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  slug = slug.replaceAll(RegExp(r'^_+|_+$'), '');
  if (slug.isEmpty) slug = 'source';
  var id = 'manual_$slug';
  var n = 2;
  while (existingIds.contains(id)) {
    id = 'manual_${slug}_$n';
    n++;
  }
  return id;
}

/// 校验输入并构造空白源。任一校验不过即返回带错结果，不构造配置。
ManualSourceResult buildManualSource({
  required String name,
  required String baseUrl,
  required SourceType type,
  Set<String> existingIds = const <String>{},
}) {
  final errors = <String>[];
  final trimmedName = name.trim();
  if (trimmedName.isEmpty) errors.add('请填写站名');
  if (!isValidManualSourceUrl(baseUrl)) {
    errors.add('地址须是 http(s) 开头的合法网址，如 https://example.com');
  }
  if (errors.isNotEmpty) return ManualSourceResult.invalid(errors);

  final normalized = normalizeManualSourceUrl(baseUrl);
  final host = Uri.parse(normalized).host;
  final config = PluginConfig(
    id: manualSourceIdFor(normalized, existingIds),
    name: trimmedName,
    type: type,
    site: SiteConfig(domain: host, baseUrl: normalized),
    parser: const ParserConfig(type: 'builtin'),
    // 仅媒体源需要 latest 路由占位（见文件头说明）：指向本站地址本身。
    routes: type == SourceType.animeSource
        ? <String, RouteConfig>{'latest': RouteConfig(url: normalized)}
        : const <String, RouteConfig>{},
  );
  // 与导入同一道关：validate 不过就不给配置，调用方不得入库。
  final validationErrors = config.validate();
  if (validationErrors.isNotEmpty) {
    return ManualSourceResult.invalid(validationErrors);
  }
  return ManualSourceResult.ok(config);
}
