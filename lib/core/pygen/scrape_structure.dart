import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// 从本次爬取到的页面原文中抽取可用于生成规则的结构事实。
///
/// 只做纯函数分析：不发任何请求，不猜站点未出现过的结构。
/// 所有选择器都从实际出现的元素推导；推导不出时为 null，
/// 调用方据此判定对应格式能不能生成、缺什么。
class ScrapedStructure {
  const ScrapedStructure({
    required this.pageUrl,
    required this.base,
    required this.domain,
    required this.pagePath,
    required this.title,
    required this.paragraphCount,
    required this.contentSelector,
    required this.chapterLinks,
    required this.chapterListSelector,
    required this.nextSelector,
    required this.searchForm,
    required this.navLinks,
    required this.cardPattern,
    required this.cardListSelector,
    required this.cardTitleSelector,
    required this.imageClusterSelector,
    required this.hasH1,
  });

  /// 本次爬取的页面地址。
  final String pageUrl;

  /// 站点基址（协议 + 主机），可能为空（地址解析失败时）。
  final String base;

  /// 主机名。
  final String domain;

  /// 被爬页面的路径部分（含前导 /）。
  final String pagePath;

  /// 页面 <title> 文本。
  final String title;

  /// 正文段落数（有实质文本的 p 标签数）。
  final int paragraphCount;

  /// 正文容器选择器（供 ruleContent 使用），无段落时为 null。
  final String? contentSelector;

  /// 形如章节的链接（文本含「第 N 章/节/话/回」），已按出现顺序去重。
  final List<ScrapedLink> chapterLinks;

  /// 章节列表选择器（供 ruleToc / chapters 使用），章节链接不足时为 null。
  final String? chapterListSelector;

  /// 「下一章/下一页」链接选择器（Legado 规则形态），未发现时为 null。
  final String? nextSelector;

  /// 站内搜索表单（GET + 具名文本输入），未发现时为 null。
  final SearchFormInfo? searchForm;

  /// 导航区链接（文本 + 绝对地址），供发现分类使用。
  final List<ScrapedLink> navLinks;

  /// 卡片详情地址规律（同形卡片链接归纳出的模式），未归纳出时为 null。
  final CardPattern? cardPattern;

  /// 卡片列表选择器（供 ruleSearch / ruleExplore / latest 使用）。
  final String? cardListSelector;

  /// 卡片内标题选择器（相对卡片元素），卡片无标题子元素时为 @text。
  final String? cardTitleSelector;

  /// 图片聚簇选择器（图片最多的容器），无聚簇时为 null。
  final String? imageClusterSelector;

  /// 页面是否有非空 h1。
  final bool hasH1;

  bool get hasParagraphs => paragraphCount > 0;
  bool get hasChapters => chapterLinks.length >= 3;
  bool get hasCards => cardPattern != null;
}

/// 一条被抽取的链接（文本 + 绝对地址）。
class ScrapedLink {
  const ScrapedLink({required this.text, required this.href});
  final String text;
  final String href;
}

/// 站内搜索表单：提交地址（绝对）与查询参数名。
class SearchFormInfo {
  const SearchFormInfo({required this.actionUrl, required this.paramName});
  final String actionUrl;
  final String paramName;
}

/// 卡片详情地址规律：公共前缀 + 占位段 + 公共后缀。
class CardPattern {
  const CardPattern({
    required this.prefix,
    required this.suffix,
    required this.count,
  });

  /// 公共前缀（以 / 结尾的路径部分，如 /manga/）。
  final String prefix;

  /// 公共后缀（如 .html），没有时为空。
  final String suffix;

  /// 归纳出该规律的卡片链接数。
  final int count;

  /// Legado / PluginConfig 通用的详情地址模式（{id} 占位）。
  String get detailPattern => '$prefix{id}$suffix';
}

/// 分析一次爬取到的页面原文，抽取结构事实。
ScrapedStructure analyzeScrapedHtml({
  required String pageUrl,
  required String html,
}) {
  final uri = Uri.tryParse(pageUrl);
  // 注意：Uri.replace(path: '', query: '', fragment: '') 会留下 "?#" 后缀，
  // 故直接拼 scheme + authority。
  final base =
      uri != null && uri.hasAuthority ? '${uri.scheme}://${uri.authority}' : '';
  final domain = uri?.host ?? '';
  final pagePath = (uri?.path.isEmpty ?? true) ? '/' : uri!.path;

  final Document doc;
  try {
    doc = html_parser.parse(html);
  } catch (_) {
    return ScrapedStructure(
      pageUrl: pageUrl,
      base: base,
      domain: domain,
      pagePath: pagePath,
      title: '',
      paragraphCount: 0,
      contentSelector: null,
      chapterLinks: const [],
      chapterListSelector: null,
      nextSelector: null,
      searchForm: null,
      navLinks: const [],
      cardPattern: null,
      cardListSelector: null,
      cardTitleSelector: null,
      imageClusterSelector: null,
      hasH1: false,
    );
  }

  final title = doc.querySelector('title')?.text.trim() ?? '';
  final h1 = doc.querySelector('h1');
  final hasH1 = h1 != null && h1.text.trim().isNotEmpty;

  final paragraphs =
      doc.querySelectorAll('p').where((p) => p.text.trim().length > 1).toList();
  final contentSelector = _deriveContentSelector(paragraphs);

  final links = _collectLinks(doc, uri);
  final chapterLinks = _chapterLinks(links);
  final chapterListSelector = chapterLinks.length >= 3
      ? _listSelectorForLinks(doc, chapterLinks, uri)
      : null;
  final nextSelector = _nextSelector(doc);
  final searchForm = _findSearchForm(doc, uri);
  final navLinks = _navLinks(doc, uri);
  final cards = _cardLinks(doc, uri);
  final cardPattern = _cardPattern(cards);
  final cardListSelector = cardPattern != null
      ? _listSelectorForLinks(doc, cards.map((c) => c.link).toList(), uri)
      : null;
  final cardTitleSelector = cards.isNotEmpty
      ? _cardTitleSelector(cards.map((c) => c.element).toList())
      : null;
  final imageClusterSelector = _imageClusterSelector(doc);

  return ScrapedStructure(
    pageUrl: pageUrl,
    base: base,
    domain: domain,
    pagePath: pagePath,
    title: title,
    paragraphCount: paragraphs.length,
    contentSelector: contentSelector,
    chapterLinks: chapterLinks,
    chapterListSelector: chapterListSelector,
    nextSelector: nextSelector,
    searchForm: searchForm,
    navLinks: navLinks,
    cardPattern: cardPattern,
    cardListSelector: cardListSelector,
    cardTitleSelector: cardTitleSelector,
    imageClusterSelector: imageClusterSelector,
    hasH1: hasH1,
  );
}

/// 收集页面内所有同站绝对链接（文本 + href + 元素）。
List<_LinkRef> _collectLinks(Document doc, Uri? baseUri) {
  final out = <_LinkRef>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    final raw = a.attributes['href']?.trim() ?? '';
    if (raw.isEmpty ||
        raw.startsWith('#') ||
        raw.startsWith('javascript:') ||
        raw.startsWith('mailto:') ||
        raw.startsWith('tel:')) {
      continue;
    }
    final resolved = baseUri?.resolve(raw) ?? Uri.tryParse(raw);
    if (resolved == null || !resolved.hasAuthority) continue;
    if (baseUri != null &&
        resolved.host != baseUri.host &&
        resolved.host != 'www.${baseUri.host}' &&
        'www.${resolved.host}' != baseUri.host) {
      continue;
    }
    final href = resolved.toString();
    if (!seen.add(href)) continue;
    out.add(_LinkRef(
      element: a,
      link: ScrapedLink(text: a.text.trim(), href: href),
    ));
  }
  return out;
}

class _LinkRef {
  const _LinkRef({required this.element, required this.link});
  final Element element;
  final ScrapedLink link;
}

/// 章节链接：文本含「第 N 章/节/话/回」。
List<ScrapedLink> _chapterLinks(List<_LinkRef> links) {
  final pattern = RegExp(r'第?\s*\d+\s*[章节话回]');
  return links
      .where((r) =>
          r.link.text.isNotEmpty &&
          r.link.text.length <= 40 &&
          pattern.hasMatch(r.link.text))
      .map((r) => r.link)
      .toList();
}

/// 列表选择器：链接们共同父元素的选择器 + ' a'；父元素无可辨标识时
/// 回落为 a[href^="公共路径前缀"]。
String? _listSelectorForLinks(
  Document doc,
  List<ScrapedLink> links,
  Uri? baseUri,
) {
  if (links.isEmpty) return null;
  // 统计各父元素承载的链接数，取承载最多的父元素。
  final counts = <Element, int>{};
  final hrefs = links.map((l) => l.href).toSet();
  for (final a in doc.querySelectorAll('a[href]')) {
    final raw = a.attributes['href']?.trim() ?? '';
    final resolved = baseUri?.resolve(raw) ?? Uri.tryParse(raw);
    if (resolved == null || !hrefs.contains(resolved.toString())) continue;
    final parent = a.parent;
    if (parent == null) continue;
    counts[parent] = (counts[parent] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  final parentSel = _selectorFor(best.key);
  if (parentSel != null && best.value >= 3) return '$parentSel a';
  // 回落：公共路径前缀。
  final prefix = _commonPathPrefix(
    links.map((l) => Uri.tryParse(l.href)?.path ?? '').toList(),
  );
  if (prefix.length >= 2) return 'a[href^="$prefix"]';
  return null;
}

/// 正文容器选择器：承载最多段落文本的具标识祖先元素；
/// 没有具标识祖先时回落为 p（与爬取抽取方式一致）。
String? _deriveContentSelector(List<Element> paragraphs) {
  if (paragraphs.isEmpty) return null;
  final total = paragraphs.fold<int>(0, (s, p) => s + p.text.trim().length);
  if (total == 0) return null;
  final scores = <Element, int>{};
  for (final p in paragraphs) {
    final len = p.text.trim().length;
    var node = p.parent;
    var depth = 0;
    while (node != null && depth < 6) {
      scores[node] = (scores[node] ?? 0) + len;
      node = node.parent;
      depth++;
    }
  }
  Element? best;
  var bestScore = 0;
  for (final entry in scores.entries) {
    final el = entry.key;
    if (el.localName == 'body' || el.localName == 'html') continue;
    if (_selectorFor(el) == null) continue;
    if (entry.value > bestScore) {
      best = el;
      bestScore = entry.value;
    }
  }
  if (best != null && bestScore >= total * 0.6) return _selectorFor(best);
  return 'p';
}

/// 「下一章/下一页」选择器：Legado 的 :contains 写法。
String? _nextSelector(Document doc) {
  const keywords = ['下一章', '下一篇', '下一页', '下一話', 'Next'];
  for (final a in doc.querySelectorAll('a[href]')) {
    final text = a.text.trim();
    for (final kw in keywords) {
      if (text.contains(kw)) return 'a:contains($kw)@href';
    }
  }
  return null;
}

/// 站内搜索表单：method 非 POST、有具名文本输入、action 同站。
SearchFormInfo? _findSearchForm(Document doc, Uri? baseUri) {
  for (final form in doc.querySelectorAll('form')) {
    final method = (form.attributes['method'] ?? 'get').toLowerCase();
    if (method == 'post') continue;
    Element? input;
    for (final candidate
        in form.querySelectorAll('input[name], input[type="search"]')) {
      final type = (candidate.attributes['type'] ?? 'text').toLowerCase();
      if (type == 'hidden' || type == 'submit' || type == 'button') continue;
      final name = candidate.attributes['name']?.trim() ?? '';
      if (name.isEmpty) continue;
      input = candidate;
      break;
    }
    if (input == null) continue;
    final action = form.attributes['action']?.trim() ?? '';
    final resolved = action.isEmpty
        ? baseUri
        : (baseUri?.resolve(action) ?? Uri.tryParse(action));
    if (resolved == null || !resolved.hasAuthority) continue;
    if (baseUri != null && resolved.host != baseUri.host) continue;
    return SearchFormInfo(
      actionUrl: resolved.toString(),
      paramName: input.attributes['name']!.trim(),
    );
  }
  return null;
}

/// 导航区链接：nav / header / 含 nav 或 menu 类名的容器内的链接。
List<ScrapedLink> _navLinks(Document doc, Uri? baseUri) {
  final containers = <Element>[];
  containers.addAll(doc.querySelectorAll('nav, header'));
  for (final el in doc.querySelectorAll('[class]')) {
    final cls = (el.attributes['class'] ?? '').toLowerCase();
    if (cls.contains('nav') || cls.contains('menu')) containers.add(el);
  }
  final out = <ScrapedLink>[];
  final seen = <String>{};
  for (final container in containers) {
    for (final a in container.querySelectorAll('a[href]')) {
      final raw = a.attributes['href']?.trim() ?? '';
      final resolved = baseUri?.resolve(raw) ?? Uri.tryParse(raw);
      if (resolved == null || !resolved.hasAuthority) continue;
      if (baseUri != null && resolved.host != baseUri.host) continue;
      final text = a.text.trim();
      if (text.isEmpty || text.length > 20) continue;
      final href = resolved.toString();
      if (!seen.add(href)) continue;
      out.add(ScrapedLink(text: text, href: href));
    }
    if (out.length >= 12) break;
  }
  return out.take(12).toList();
}

class _CardRef {
  const _CardRef({required this.element, required this.link});
  final Element element;
  final ScrapedLink link;
}

/// 卡片链接：含图片且有标题文本的链接。
List<_CardRef> _cardLinks(Document doc, Uri? baseUri) {
  final out = <_CardRef>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    if (a.querySelector('img') == null) continue;
    final text = a.text.trim();
    if (text.isEmpty || text.length > 60) continue;
    final raw = a.attributes['href']?.trim() ?? '';
    final resolved = baseUri?.resolve(raw) ?? Uri.tryParse(raw);
    if (resolved == null || !resolved.hasAuthority) continue;
    if (baseUri != null && resolved.host != baseUri.host) continue;
    final href = resolved.toString();
    if (!seen.add(href)) continue;
    out.add(_CardRef(element: a, link: ScrapedLink(text: text, href: href)));
  }
  return out;
}

/// 卡片详情地址规律：把卡片链接按「去掉最后一段的路径」分组，
/// 取最大的一组（不少于 3 条）；公共后缀取组内共有的文件后缀。
CardPattern? _cardPattern(List<_CardRef> cards) {
  if (cards.length < 3) return null;
  final groups = <String, List<String>>{};
  for (final card in cards) {
    var path = Uri.tryParse(card.link.href)?.path ?? '';
    // 尾斜杠详情地址（/book/123/）先去掉尾斜杠再取末段，否则每条
    // 链接自成一组、归纳不出规律。
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final slash = path.lastIndexOf('/');
    if (slash <= 0) continue;
    final prefix = path.substring(0, slash + 1);
    (groups[prefix] ??= <String>[]).add(path);
  }
  if (groups.isEmpty) return null;
  final best =
      groups.entries.reduce((a, b) => a.value.length >= b.value.length ? a : b);
  if (best.value.length < 3) return null;
  var suffix = '';
  final first = best.value.first;
  final dot = first.lastIndexOf('.');
  final slash = first.lastIndexOf('/');
  if (dot > slash) {
    final candidate = first.substring(dot);
    if (best.value.every((p) => p.endsWith(candidate)) &&
        RegExp(r'^\.[a-zA-Z0-9]{2,5}$').hasMatch(candidate)) {
      suffix = candidate;
    }
  }
  return CardPattern(
    prefix: best.key,
    suffix: suffix,
    count: best.value.length,
  );
}

/// 卡片内标题选择器：多数卡片含同一标题子标签时用该标签，
/// 否则用 @text（取卡片自身文本）。
String? _cardTitleSelector(List<Element> cards) {
  if (cards.isEmpty) return null;
  for (final tag in ['h3', 'h2', 'h4', 'p']) {
    final hit = cards.where((c) => c.querySelector(tag) != null).length;
    if (hit * 2 >= cards.length) return '$tag@text';
  }
  return '@text';
}

/// 图片聚簇选择器：承载图片最多的具标识容器 + ' img'。
///
/// 只统计不在链接内的图片：章节正文图是独立 <img>，卡片封面图都在
/// <a> 里；把封面也算进来会误把列表页当成图片页。
String? _imageClusterSelector(Document doc) {
  final counts = <Element, int>{};
  for (final img in doc.querySelectorAll('img[src], img[data-src]')) {
    if (_insideAnchor(img)) continue;
    var node = img.parent;
    var depth = 0;
    while (node != null && depth < 4) {
      counts[node] = (counts[node] ?? 0) + 1;
      node = node.parent;
      depth++;
    }
  }
  Element? best;
  var bestCount = 0;
  for (final entry in counts.entries) {
    final el = entry.key;
    if (el.localName == 'body' || el.localName == 'html') continue;
    final sel = _selectorFor(el);
    if (sel == null) continue;
    if (entry.value > bestCount) {
      best = el;
      bestCount = entry.value;
    }
  }
  if (best == null || bestCount < 3) return null;
  return '${_selectorFor(best)} img';
}

/// 元素是否在 <a> 链接内（向上追溯 6 层）。
bool _insideAnchor(Element el) {
  var node = el.parent;
  var depth = 0;
  while (node != null && depth < 6) {
    if (node.localName == 'a') return true;
    node = node.parent;
    depth++;
  }
  return false;
}

/// 元素的单层 CSS 选择器：优先 #id，其次 tag.class；无可辨标识时 null。
String? _selectorFor(Element el) {
  final tag = el.localName ?? '';
  if (tag.isEmpty) return null;
  final id = el.id.trim();
  if (_isSafeIdent(id)) return '#$id';
  for (final cls in el.classes) {
    if (_isSafeIdent(cls)) return '$tag.$cls';
  }
  return null;
}

bool _isSafeIdent(String value) => RegExp(r'^[A-Za-z_][\w-]*$').hasMatch(value);

/// 多条路径的公共前缀（截断到最后一个 /）。
String _commonPathPrefix(List<String> paths) {
  if (paths.isEmpty) return '';
  var prefix = paths.first;
  for (final path in paths.skip(1)) {
    var i = 0;
    while (i < prefix.length && i < path.length && prefix[i] == path[i]) {
      i++;
    }
    prefix = prefix.substring(0, i);
  }
  final slash = prefix.lastIndexOf('/');
  if (slash < 0) return '';
  return prefix.substring(0, slash + 1);
}
