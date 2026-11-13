import 'dart:convert';

import '../models/plugin_config.dart';
import '../scraper/web_scrape_service.dart';
import '../services/source_repository.dart';
import '../../features/shuyuan/shuyuan_adapter.dart';
import '../../features/shuyuan/shuyuan_source_service.dart';
import 'onekey_py_service.dart';
import 'scrape_structure.dart';

/// 爬取后可生成的格式。
enum ScrapeGenFormat {
  /// 视频 py 蜘蛛（现有的一键生成，不走本文件）。
  py,

  /// Legado 书源 JSON（小说/文章模式）。
  bookJson,

  /// Legado 书源 XML（与 JSON 版同一套规则）。
  bookXml,

  /// 漫画规则 JSON（PluginConfig mangaSource，漫画模式）。
  comicJson,

  /// TXT：内容与本模式的 JSON 版相同，仅后缀为 .txt。
  txt,
}

/// 格式的注册去向。
enum FormatDestination {
  /// 站点列表（py）。
  siteList,

  /// 书源登记（书源 JSON / XML / TXT 书源版）。
  bookSources,

  /// 漫画源登记（漫画 JSON / TXT 漫画版）。
  comicSources,
}

extension ScrapeGenFormatX on ScrapeGenFormat {
  String get label {
    switch (this) {
      case ScrapeGenFormat.py:
        return 'py 视频蜘蛛';
      case ScrapeGenFormat.bookJson:
        return 'JSON 书源';
      case ScrapeGenFormat.bookXml:
        return 'XML 书源';
      case ScrapeGenFormat.comicJson:
        return 'JSON 漫画规则';
      case ScrapeGenFormat.txt:
        return 'TXT';
    }
  }

  String get fileExtension {
    switch (this) {
      case ScrapeGenFormat.py:
        return 'py';
      case ScrapeGenFormat.bookJson:
        return 'json';
      case ScrapeGenFormat.bookXml:
        return 'xml';
      case ScrapeGenFormat.comicJson:
        return 'json';
      case ScrapeGenFormat.txt:
        return 'txt';
    }
  }
}

/// 格式生成失败时抛出的异常，message 即要报给用户的真实原因。
class ScrapeFormatException implements Exception {
  const ScrapeFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 某个格式在本次爬取数据下的可用性。
class FormatAvailability {
  const FormatAvailability({
    required this.format,
    required this.available,
    this.missingReason,
  });

  final ScrapeGenFormat format;
  final bool available;

  /// 不可用时缺什么（已写明具体缺项）；可用时为 null。
  final String? missingReason;
}

/// 按本次爬取数据规划各格式的可用性。
///
/// 只列出与当前模式相关的格式：py 全模式；书源类只在小说/文章模式；
/// 漫画类只在漫画模式；TXT 跟随本模式的 JSON 格式（视频/通用模式没有
/// JSON 产物，故不提供 TXT——py 内容存为 .txt 导入侧认不出）。
List<FormatAvailability> planScrapeFormats({
  required ScrapeMode mode,
  required ScrapeResult result,
}) {
  final structure = analyzeScrapedHtml(
    pageUrl: result.url,
    html: result.html,
  );
  final out = <FormatAvailability>[];

  final pyReason = _pyMissingReason(result, structure);
  out.add(FormatAvailability(
    format: ScrapeGenFormat.py,
    available: pyReason == null,
    missingReason: pyReason,
  ));

  if (mode == ScrapeMode.novel || mode == ScrapeMode.article) {
    final bookReason = _bookMissingReason(structure);
    out.add(FormatAvailability(
      format: ScrapeGenFormat.bookJson,
      available: bookReason == null,
      missingReason: bookReason,
    ));
    out.add(FormatAvailability(
      format: ScrapeGenFormat.bookXml,
      available: bookReason == null,
      missingReason: bookReason,
    ));
    out.add(FormatAvailability(
      format: ScrapeGenFormat.txt,
      available: bookReason == null,
      missingReason: bookReason,
    ));
  }

  if (mode == ScrapeMode.comic) {
    final comicReason = _comicMissingReason(structure);
    out.add(FormatAvailability(
      format: ScrapeGenFormat.comicJson,
      available: comicReason == null,
      missingReason: comicReason,
    ));
    out.add(FormatAvailability(
      format: ScrapeGenFormat.txt,
      available: comicReason == null,
      missingReason: comicReason,
    ));
  }

  return out;
}

String? _pyMissingReason(ScrapeResult result, ScrapedStructure structure) {
  if (result.html.trim().isEmpty) return '页面内容为空，无法生成';
  if (structure.base.isEmpty) return '无法解析站点基址';
  return null;
}

String? _bookMissingReason(ScrapedStructure structure) {
  final missing = <String>[];
  if (structure.base.isEmpty) missing.add('无法解析站点基址');
  if (!structure.hasParagraphs && !structure.hasChapters) {
    missing.add('页面没有正文段落，也没有章节链接');
  }
  if (missing.isEmpty) return null;
  return missing.join('；');
}

String? _comicMissingReason(ScrapedStructure structure) {
  final missing = <String>[];
  if (structure.base.isEmpty) missing.add('无法解析站点基址');
  if (!structure.hasCards) missing.add('页面没有可归纳的卡片详情地址规律');
  if (structure.cardListSelector == null) {
    missing.add('无法推导卡片列表选择器');
  }
  if (structure.imageClusterSelector == null) {
    missing.add('页面没有图片聚簇');
  }
  if (!structure.hasChapters) missing.add('页面没有章节链接');
  if (structure.hasChapters && structure.chapterListSelector == null) {
    missing.add('无法推导章节列表选择器');
  }
  if (missing.isEmpty) return null;
  return missing.join('；');
}

/// 生成出的格式产物（py 除外，py 仍走 OneKeyPyService）。
class GeneratedFormatArtifact {
  const GeneratedFormatArtifact({
    required this.format,
    required this.destination,
    required this.content,
    required this.fileName,
    required this.metaLines,
  });

  final ScrapeGenFormat format;
  final FormatDestination destination;
  final String content;
  final String fileName;

  /// 推导出的部分与未推导出的部分（诚实说明，展示用）。
  final List<String> metaLines;
}

/// 生成指定格式的产物（py 除外）。
///
/// 生成后立即用 App 自身的解析器校验：书源过 parseSources +
/// ShuyuanAdapter，漫画规则过 parseMixedSources；校验不过即抛
/// ScrapeFormatException，不产出导入不了的假规则。
GeneratedFormatArtifact generateScrapeFormat({
  required ScrapeGenFormat format,
  required ScrapeMode mode,
  required ScrapeResult result,
  required String siteName,
}) {
  if (format == ScrapeGenFormat.py) {
    throw const ScrapeFormatException('py 格式走现有的一键生成');
  }
  final structure = analyzeScrapedHtml(
    pageUrl: result.url,
    html: result.html,
  );
  final name = siteName.trim().isEmpty ? structure.domain : siteName.trim();
  final slug = _fileSlug(structure.domain, name);

  // 门禁：数据不足时直接报缺项，不产出假规则。
  final isComic = format == ScrapeGenFormat.comicJson ||
      (format == ScrapeGenFormat.txt && mode == ScrapeMode.comic);
  final missing =
      isComic ? _comicMissingReason(structure) : _bookMissingReason(structure);
  if (missing != null) {
    throw ScrapeFormatException('数据不足，无法生成${format.label}：$missing');
  }

  switch (format) {
    case ScrapeGenFormat.bookJson:
      final map = buildBookSourceMap(structure: structure, siteName: name);
      final text = const JsonEncoder.withIndent('  ').convert(map);
      _validateBookSourceText(text);
      return GeneratedFormatArtifact(
        format: format,
        destination: FormatDestination.bookSources,
        content: text,
        fileName: '${slug}_booksource.json',
        metaLines: _bookMetaLines(structure),
      );
    case ScrapeGenFormat.bookXml:
      final map = buildBookSourceMap(structure: structure, siteName: name);
      final jsonText = const JsonEncoder.withIndent('  ').convert(map);
      final xmlText = buildBookSourceXml(map);
      _validateBookSourceXml(xmlText, jsonText);
      return GeneratedFormatArtifact(
        format: format,
        destination: FormatDestination.bookSources,
        content: xmlText,
        fileName: '${slug}_booksource.xml',
        metaLines: _bookMetaLines(structure),
      );
    case ScrapeGenFormat.comicJson:
      final map = buildComicRuleMap(structure: structure, siteName: name);
      final text = const JsonEncoder.withIndent('  ').convert(map);
      _validateComicRuleText(text);
      return GeneratedFormatArtifact(
        format: format,
        destination: FormatDestination.comicSources,
        content: text,
        fileName: '${slug}_manga.json',
        metaLines: _comicMetaLines(structure),
      );
    case ScrapeGenFormat.txt:
      if (mode == ScrapeMode.comic) {
        final map = buildComicRuleMap(structure: structure, siteName: name);
        final text = const JsonEncoder.withIndent('  ').convert(map);
        _validateComicRuleText(text);
        return GeneratedFormatArtifact(
          format: format,
          destination: FormatDestination.comicSources,
          content: text,
          fileName: '${slug}_manga.txt',
          metaLines: [
            '内容与 JSON 漫画规则相同，仅后缀为 .txt，导入时按内容识别',
            ..._comicMetaLines(structure),
          ],
        );
      }
      final map = buildBookSourceMap(structure: structure, siteName: name);
      final text = const JsonEncoder.withIndent('  ').convert(map);
      _validateBookSourceText(text);
      return GeneratedFormatArtifact(
        format: format,
        destination: FormatDestination.bookSources,
        content: text,
        fileName: '${slug}_booksource.txt',
        metaLines: [
          '内容与 JSON 书源相同，仅后缀为 .txt，导入时按内容识别',
          ..._bookMetaLines(structure),
        ],
      );
    case ScrapeGenFormat.py:
      throw const ScrapeFormatException('py 格式走现有的一键生成');
  }
}

/// 从结构事实推导 Legado 书源 map（bookSourceType 0）。
///
/// 只含能推导出的规则：搜索/发现规则需要卡片列表结构佐证，
/// 没有卡片结构时不写搜索与发现（不编假规则）。
Map<String, dynamic> buildBookSourceMap({
  required ScrapedStructure structure,
  required String siteName,
}) {
  final map = <String, dynamic>{
    'bookSourceName': siteName,
    'bookSourceUrl': structure.base,
    'bookSourceType': 0,
    'bookSourceGroup': '网页爬取',
  };

  final derived = <String>[];
  if (structure.hasParagraphs) derived.add('正文');
  if (structure.hasChapters) derived.add('目录');
  if (structure.searchForm != null && structure.hasCards) {
    derived.add('搜索');
  }
  if (structure.navLinks.isNotEmpty && structure.hasCards) {
    derived.add('发现');
  }
  map['bookSourceComment'] =
      '网页爬取自动生成，含${derived.isEmpty ? '基础信息' : derived.join('、')}规则';

  final cardList = structure.cardListSelector;
  if (structure.searchForm != null && structure.hasCards && cardList != null) {
    final form = structure.searchForm!;
    map['searchUrl'] = _withQueryParam(
      form.actionUrl,
      form.paramName,
      '{{key}}',
    );
    map['ruleSearch'] = _listRuleMap(structure, cardList);
  }

  if (structure.navLinks.isNotEmpty && structure.hasCards && cardList != null) {
    map['exploreUrl'] =
        structure.navLinks.map((l) => '${l.text}::${l.href}').join('\n');
    map['ruleExplore'] = _listRuleMap(structure, cardList);
  }

  if (structure.hasH1) {
    map['ruleBookInfo'] = <String, dynamic>{'name': 'h1@text'};
  }

  if (structure.hasChapters && structure.chapterListSelector != null) {
    final toc = <String, dynamic>{
      'chapterList': structure.chapterListSelector,
      'chapterName': '@text',
      'chapterUrl': '@href',
    };
    if (structure.nextSelector != null) {
      toc['nextTocUrl'] = structure.nextSelector;
    }
    map['ruleToc'] = toc;
  }

  if (structure.hasParagraphs && structure.contentSelector != null) {
    final content = <String, dynamic>{
      'content': '${structure.contentSelector}@textNodes',
    };
    if (structure.hasH1) content['title'] = 'h1@text';
    if (structure.nextSelector != null) {
      content['nextContentUrl'] = structure.nextSelector;
    }
    map['ruleContent'] = content;
  }

  return map;
}

/// 列表类规则（搜索/发现共用）：从卡片结构推导。
Map<String, dynamic> _listRuleMap(
  ScrapedStructure structure,
  String cardList,
) {
  return <String, dynamic>{
    'bookList': cardList,
    'bookName': structure.cardTitleSelector ?? '@text',
    'bookUrl': '@href',
    'bookCoverUrl': 'img@src||img@data-src',
  };
}

/// 书源 map 转 Legado XML 文本。
///
/// 注意：只写字符串值标签。XML 解析后所有值都是字符串，
/// 而 ShuyuanSource.fromJson 对 bookSourceType / enabled 这类
/// 字段做 `as int?` / `as bool?` 强转，写了反而解析失败；
/// 省略后默认值恰好是 bookSourceType 0 与 enabled true。
String buildBookSourceXml(Map<String, dynamic> sourceMap) {
  const ruleKeys = {
    'ruleSearch',
    'ruleExplore',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
  };
  final buf = StringBuffer()..writeln('<sources>');
  buf.writeln('  <bookSource>');
  for (final entry in sourceMap.entries) {
    if (entry.key == 'bookSourceType') continue;
    final value = ruleKeys.contains(entry.key)
        ? jsonEncode(entry.value)
        : entry.value.toString();
    buf.writeln(
      '    <${entry.key}>${_xmlEscape(value)}</${entry.key}>',
    );
  }
  buf.writeln('  </bookSource>');
  buf.writeln('</sources>');
  return buf.toString();
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 从结构事实推导漫画规则 map（PluginConfig mangaSource，builtin 解析）。
Map<String, dynamic> buildComicRuleMap({
  required ScrapedStructure structure,
  required String siteName,
}) {
  final base = structure.base;
  final listPageUrl = '$base${structure.pagePath}';
  final cardList = structure.cardListSelector!;
  final listSelectors = <String, dynamic>{
    'list': cardList,
    'title': structure.cardTitleSelector ?? '@text',
    'cover': 'img@src||img@data-src',
    'id': '@href',
  };

  final routes = <String, dynamic>{
    'latest': {'url': listPageUrl, 'method': 'GET'},
    'explore': {'url': listPageUrl, 'method': 'GET'},
  };
  final selectors = <String, dynamic>{
    'latest': Map<String, dynamic>.from(listSelectors),
    'explore': Map<String, dynamic>.from(listSelectors),
  };

  final categoryPattern = _categoryPattern(structure.navLinks);
  if (categoryPattern != null) {
    routes['category'] = {
      'url': '$base$categoryPattern',
      'method': 'GET',
    };
    selectors['category'] = Map<String, dynamic>.from(listSelectors);
  }

  if (structure.searchForm != null) {
    final form = structure.searchForm!;
    routes['search'] = {
      'url': _withQueryParam(form.actionUrl, form.paramName, '{keyword}'),
      'method': 'GET',
    };
    selectors['search'] = Map<String, dynamic>.from(listSelectors);
  }

  // 详情 / 章节 / 图片路由：照树内既定形态（mangacopy 等已验规则）。
  // 列表与章节的 id 选择器都是 a@href（详情/章节地址本身），引擎调用时
  // 只传 {id} / {chapterId}，故路由直接用占位符直通该地址，不再拼前缀
  //（拼前缀会把地址拼成双 host 坏链；见 PluginConfig.resolveRouteUrl）。
  routes['detail'] = {'url': '{id}', 'method': 'GET'};
  routes['chapters'] = {'url': '{id}', 'method': 'GET'};
  routes['images'] = {'url': '{chapterId}', 'method': 'GET'};

  if (structure.hasH1) {
    selectors['detail'] = <String, dynamic>{'title': 'h1@text'};
  }
  selectors['chapters'] = <String, dynamic>{
    'list': structure.chapterListSelector,
    'title': '@text',
    'id': '@href',
    'url': '@href',
  };
  selectors['images'] = <String, dynamic>{
    'list': structure.imageClusterSelector,
    'fallbackUrl': 'img@data-src||img@data-original||img@src',
  };

  final map = <String, dynamic>{
    'id': 'manga_${_idSlug(structure.domain)}',
    'name': siteName,
    'version': 1,
    'type': 'mangaSource',
    'responseType': 'html',
    'site': {'domain': structure.domain, 'baseUrl': base},
    'parser': {'type': 'builtin'},
    'routes': routes,
    'selectors': selectors,
    'antiHotlinking': {'referer': base},
  };

  if (categoryPattern != null) {
    map['category'] = {
      'categoryEntries': structure.navLinks
          .map((l) => {
                'id': _lastPathSegment(l.href),
                'title': l.text,
              })
          .where((e) => (e['id'] as String).isNotEmpty)
          .toList(),
    };
  }

  return map;
}

/// 分类路由模式：导航链接共用前缀、仅末段不同时归纳为
/// `前缀{category}后缀`；归纳不出时为 null。
String? _categoryPattern(List<ScrapedLink> navLinks) {
  if (navLinks.length < 2) return null;
  final paths = navLinks
      .map((l) => Uri.tryParse(l.href)?.path ?? '')
      .map((p) =>
          p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p)
      .where((p) => p.isNotEmpty)
      .toList();
  if (paths.length < 2) return null;
  var prefix = paths.first;
  for (final path in paths.skip(1)) {
    var i = 0;
    while (i < prefix.length && i < path.length && prefix[i] == path[i]) {
      i++;
    }
    prefix = prefix.substring(0, i);
  }
  final slash = prefix.lastIndexOf('/');
  if (slash <= 0) return null;
  prefix = prefix.substring(0, slash + 1);
  final tails = paths.map((p) => p.substring(prefix.length)).toList();
  if (tails.any((t) => t.isEmpty || t.contains('/'))) return null;
  if (tails.toSet().length < 2) return null;
  var suffix = '';
  final first = tails.first;
  final dot = first.lastIndexOf('.');
  if (dot > 0) {
    final candidate = first.substring(dot);
    if (tails.every((t) => t.endsWith(candidate))) suffix = candidate;
  }
  return '$prefix{category}$suffix';
}

String _lastPathSegment(String href) {
  final path = Uri.tryParse(href)?.path ?? '';
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '' : segments.last;
}

/// 给 URL 追加一个查询参数（占位符不做 URL 编码，保持原样）。
String _withQueryParam(String url, String name, String placeholder) {
  final sep = url.contains('?')
      ? (url.endsWith('?') || url.endsWith('&') ? '' : '&')
      : '?';
  return '$url$sep$name=$placeholder';
}

String _idSlug(String domain) {
  final slug = domain
      .replaceAll(RegExp(r'^www\.'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'site' : slug;
}

String _fileSlug(String domain, String siteName) {
  final fromDomain = _idSlug(domain);
  if (fromDomain != 'site') return fromDomain;
  final cleaned = OneKeyPyService.safeName(siteName);
  return cleaned.isEmpty ? 'site' : cleaned;
}

List<String> _bookMetaLines(ScrapedStructure structure) {
  final lines = <String>[];
  if (structure.hasParagraphs && structure.contentSelector != null) {
    lines.add(
        '正文规则：${structure.contentSelector}（${structure.paragraphCount} 段）');
  } else {
    lines.add('正文规则：未推导（页面没有正文段落）');
  }
  if (structure.hasChapters && structure.chapterListSelector != null) {
    lines.add('目录规则：${structure.chapterLinks.length} 条章节链接');
  } else {
    lines.add('目录规则：未推导（页面没有章节链接）');
  }
  if (structure.searchForm != null && structure.hasCards) {
    lines.add('搜索规则：已推导');
  } else {
    lines.add('搜索规则：未推导（缺少搜索表单或结果列表结构）');
  }
  if (structure.navLinks.isNotEmpty && structure.hasCards) {
    lines.add('发现规则：${structure.navLinks.length} 个分类');
  } else {
    lines.add('发现规则：未推导（缺少导航分类或列表结构）');
  }
  return lines;
}

List<String> _comicMetaLines(ScrapedStructure structure) {
  final lines = <String>[];
  lines.add('详情地址：${structure.cardPattern?.detailPattern ?? '未推导'}');
  lines.add('章节规则：${structure.chapterLinks.length} 条章节链接');
  lines.add('图片规则：${structure.imageClusterSelector ?? '未推导'}');
  if (structure.searchForm != null) {
    lines.add('搜索路由：已推导');
  } else {
    lines.add('搜索路由：未推导（未发现搜索表单）');
  }
  if (_categoryPattern(structure.navLinks) != null) {
    lines.add('分类路由：${structure.navLinks.length} 个分类');
  } else {
    lines.add('分类路由：未推导（导航链接无统一规律）');
  }
  return lines;
}

// ── 自身解析器校验 ──────────────────────────────────────────────

void _validateBookSourceText(String text) {
  final service = ShuyuanSourceService();
  try {
    final sources = service.parseSources(text);
    if (sources.length != 1) {
      throw ScrapeFormatException(
        '生成的书源未通过自身解析：解析出 ${sources.length} 条源',
      );
    }
    final source = sources.first;
    if (!source.isValid || source.bookSourceType != 0) {
      throw const ScrapeFormatException(
        '生成的书源未通过自身解析：源无效或不是文本类书源',
      );
    }
    final config = ShuyuanAdapter.toPluginConfig(source);
    if (config.type != SourceType.novelSource) {
      throw const ScrapeFormatException(
        '生成的书源未通过自身解析：适配后不是小说源',
      );
    }
  } on ScrapeFormatException {
    rethrow;
  } catch (e) {
    throw ScrapeFormatException('生成的书源未通过自身解析：$e');
  } finally {
    service.close();
  }
}

void _validateBookSourceXml(String xmlText, String jsonText) {
  final service = ShuyuanSourceService();
  try {
    final fromXml = service.parseSources(xmlText);
    if (fromXml.length != 1 || !fromXml.first.isValid) {
      throw const ScrapeFormatException(
        '生成的 XML 书源未通过自身解析：解析不到有效源',
      );
    }
    final fromJson = service.parseSources(jsonText);
    if (fromJson.length != 1) {
      throw const ScrapeFormatException('生成的书源未通过自身解析');
    }
    // XML 版与 JSON 版的规则必须往返一致（ShuyuanSource 的规则保持
    // Map 形态，直接比较 Map 的 JSON 编码）。
    final a = fromXml.first;
    final b = fromJson.first;
    final same = jsonEncode(a.ruleSearch) == jsonEncode(b.ruleSearch) &&
        jsonEncode(a.ruleExplore) == jsonEncode(b.ruleExplore) &&
        jsonEncode(a.ruleBookInfo) == jsonEncode(b.ruleBookInfo) &&
        jsonEncode(a.ruleToc) == jsonEncode(b.ruleToc) &&
        jsonEncode(a.ruleContent) == jsonEncode(b.ruleContent) &&
        a.bookSourceName == b.bookSourceName &&
        a.bookSourceUrl == b.bookSourceUrl &&
        a.searchUrl == b.searchUrl &&
        a.exploreUrl == b.exploreUrl;
    if (!same) {
      throw const ScrapeFormatException(
        '生成的 XML 书源与 JSON 版规则不一致',
      );
    }
  } on ScrapeFormatException {
    rethrow;
  } catch (e) {
    throw ScrapeFormatException('生成的 XML 书源未通过自身解析：$e');
  } finally {
    service.close();
  }
}

void _validateComicRuleText(String text) {
  try {
    final configs = SourceRepository.parseMixedSources(text);
    if (configs.length != 1) {
      throw ScrapeFormatException(
        '生成的漫画规则未通过自身解析：解析出 ${configs.length} 条源',
      );
    }
    if (configs.first.type != SourceType.mangaSource) {
      throw const ScrapeFormatException(
        '生成的漫画规则未通过自身解析：解析后不是漫画源',
      );
    }
  } on ScrapeFormatException {
    rethrow;
  } catch (e) {
    throw ScrapeFormatException('生成的漫画规则未通过自身解析：$e');
  }
}

// ── 注册（走各自的登记处） ───────────────────────────────────────

/// 把书源文本（JSON / XML / TXT 书源版）注册进书源登记。
///
/// 路径与书源导入页一致：parseSources → ShuyuanAdapter → addSource。
Future<PluginConfig> registerBookSourceText({
  required SourceRepository repo,
  required String text,
}) async {
  final service = ShuyuanSourceService();
  try {
    final sources = service.parseSources(text);
    final valid =
        sources.where((s) => s.isValid && s.bookSourceType == 0).toList();
    if (valid.isEmpty) {
      throw const ScrapeFormatException('书源文本解析不到有效的文本类书源');
    }
    final config = ShuyuanAdapter.toPluginConfig(valid.first);
    repo.addSource(config);
    return repo.getById(config.id) ?? config;
  } on ScrapeFormatException {
    rethrow;
  } catch (e) {
    throw ScrapeFormatException('书源文本解析失败：$e');
  } finally {
    service.close();
  }
}

/// 把规则 JSON 文本（漫画规则 / TXT 漫画版）注册进漫画源登记。
Future<PluginConfig> registerRuleJsonText({
  required SourceRepository repo,
  required String text,
}) async {
  try {
    final configs = SourceRepository.parseMixedSources(text);
    if (configs.isEmpty) {
      throw const ScrapeFormatException('规则文本解析不到有效源');
    }
    for (final config in configs) {
      repo.addSource(config);
    }
    return repo.getById(configs.first.id) ?? configs.first;
  } on ScrapeFormatException {
    rethrow;
  } catch (e) {
    throw ScrapeFormatException('规则文本解析失败：$e');
  }
}
