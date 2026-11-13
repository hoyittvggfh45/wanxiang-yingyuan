/// 红果榜单解析。
///
/// 移植自火蚁TV Go 核 `provider_rankings_hongguo.go` 与
/// `provider_rankings_parse.go`：优先解析网页 `_ROUTER_DATA` 里的 rankList，
/// 其次解析 JSON-LD，最后解析榜单 HTML 文章节点。三种来源互相印证页码，
/// 对不上时报格式错误，绝不把错页数据当成当前页。
library;

import 'dart:convert';

import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

import 'hongguo_models.dart';

/// 榜单定义（对应 Go `rankingBoards` 里的红果四榜）。
class HongguoRankingBoard {
  const HongguoRankingBoard({
    required this.id,
    required this.name,
    required this.description,
    required this.path,
    required this.upstreamKey,
  });

  final String id;
  final String name;
  final String description;
  final String path;
  final String upstreamKey;
}

const List<HongguoRankingBoard> hongguoRankingBoards = <HongguoRankingBoard>[
  HongguoRankingBoard(
    id: 'hongguo-hot',
    name: '总热播榜',
    description: '红果观看、互动等综合热度；每日更新。',
    path: 'hot-drama',
    upstreamKey: 'hongguo',
  ),
  HongguoRankingBoard(
    id: 'hongguo-real',
    name: '真人剧榜',
    description: '红果真人剧热播榜；每日更新。',
    path: 'hot-real-drama',
    upstreamKey: 'real',
  ),
  HongguoRankingBoard(
    id: 'hongguo-comic',
    name: '漫剧榜',
    description: '红果漫剧热播榜；每日更新。',
    path: 'hot-comic-drama',
    upstreamKey: 'comic',
  ),
  HongguoRankingBoard(
    id: 'hongguo-ai',
    name: 'AI剧榜',
    description: '红果 AI 剧热播榜；每日更新。',
    path: 'hot-ai-drama',
    upstreamKey: 'ai',
  ),
];

/// 榜单条目。
class HongguoRankingItem {
  const HongguoRankingItem(
      {required this.rank, required this.drama, this.metric = ''});

  final int rank;
  final HongguoDrama drama;
  final String metric;
}

/// 榜单页。
class HongguoRankingPage {
  const HongguoRankingPage({
    required this.items,
    required this.hasMore,
    required this.totalPages,
    this.updatedText = '',
  });

  final List<HongguoRankingItem> items;
  final bool hasMore;
  final int totalPages;
  final String updatedText;
}

class HongguoRankingIncomplete implements Exception {
  const HongguoRankingIncomplete([this.message = '红果榜单数据尚未完整返回，请稍后重试']);

  final String message;

  @override
  String toString() => message;
}

class HongguoRankingFormat implements Exception {
  const HongguoRankingFormat([this.message = '红果榜单格式或分页已变化，请稍后重试']);

  final String message;

  @override
  String toString() => message;
}

final RegExp _rankingMetric = RegExp(r'^[0-9]+(?:\.[0-9]+)?[万亿]?热度$');
final RegExp _jsonLdPattern = RegExp(
  r'<script\b[^>]*type=["' +
      "'" +
      r']application/ld\+json["' +
      "'" +
      r'][^>]*>(.*?)</script>',
  caseSensitive: false,
  dotAll: true,
);

/// 解析榜单页 HTML（对应 Go `parseHongguoRanking` + `parseHongguoRankingDocument`）。
HongguoRankingPage parseHongguoRanking(
    String body, HongguoRankingBoard board, int page) {
  final String loaderKey = 'rank_${board.path}/page';
  final Map<String, dynamic> loader = hongguoNestedMap(
    parseHongguoRouterData(body),
    <String>['loaderData', loaderKey],
  );
  if (loader.isNotEmpty &&
      (hongguoMapString(loader, <String>['rankKey']) != board.upstreamKey ||
          hongguoMapString(loader, <String>['pageNum']) != page.toString())) {
    throw const HongguoRankingFormat();
  }
  final Map<String, dynamic> content =
      hongguoNestedMap(loader, <String>['content']);
  if (content.isNotEmpty) {
    final HongguoRankingPage? fromRouter =
        _rankingFromRouterContent(content, board, page);
    if (fromRouter != null) return fromRouter;
  }
  return _rankingFromDocument(body, board, page, loader);
}

HongguoRankingPage? _rankingFromRouterContent(
  Map<String, dynamic> content,
  HongguoRankingBoard board,
  int page,
) {
  if (content['isSuccess'] != true) return null;
  final Object? rowsRaw = content['rankList'];
  if (rowsRaw is! List) return null;
  final Map<String, dynamic> pagination =
      hongguoNestedMap(content, <String>['pagination']);
  final int pageNum =
      int.tryParse(hongguoMapString(pagination, <String>['pageNum'])) ?? page;
  final int totalPages =
      int.tryParse(hongguoMapString(pagination, <String>['totalPages'])) ??
          page;
  if (pageNum != page) throw const HongguoRankingFormat();
  final List<HongguoRankingItem> items = <HongguoRankingItem>[];
  for (final Object? row in rowsRaw) {
    if (row is! Map) continue;
    final Map<String, dynamic> map = row.cast<String, dynamic>();
    final String seriesId = hongguoMapString(map, <String>['seriesId', 'id']);
    final int rank = int.tryParse(hongguoMapString(map, <String>['rank'])) ?? 0;
    final String title = hongguoMapString(map, <String>['title']).trim();
    if (!hongguoNumericId.hasMatch(seriesId) || rank <= 0 || title.isEmpty)
      continue;
    final Object? coverRaw = map['cover'];
    String cover = '';
    if (coverRaw is String) {
      cover = coverRaw;
    } else if (coverRaw is Map) {
      cover = hongguoMapString(
          coverRaw.cast<String, dynamic>(), <String>['url', 'src']);
    }
    final List<String> tags = hongguoStringList(map, 'tags');
    items.add(HongguoRankingItem(
      rank: rank,
      drama: HongguoDrama(
        id: HongguoDrama.dramaId(seriesId),
        sourceId: seriesId,
        title: title,
        cover: cover,
        intro: hongguoMapString(map, <String>['description']),
        categoryName: tags.isNotEmpty ? tags.first : '',
        tags: tags,
        score: hongguoMapString(map, <String>['scoreText']),
        heat: hongguoMapString(map, <String>['heatText']),
      ),
      metric: hongguoMapString(map, <String>['heatText']),
    ));
  }
  if (items.isEmpty) return null;
  items.sort(
      (HongguoRankingItem a, HongguoRankingItem b) => a.rank.compareTo(b.rank));
  return HongguoRankingPage(
    items: items,
    hasMore: page < totalPages,
    totalPages: totalPages,
  );
}

HongguoRankingPage _rankingFromDocument(
  String body,
  HongguoRankingBoard board,
  int page,
  Map<String, dynamic> loader,
) {
  if (body.length > 4 * 1024 * 1024) throw const HongguoRankingFormat();
  final html_dom.Document document = html_parser.parse(body);
  bool identified = loader.isNotEmpty;
  for (final html_dom.Element node
      in document.querySelectorAll('link[rel="canonical"]')) {
    final int? actual = _rankingUrlPage(node.attributes['href'] ?? '', board);
    if (actual == null || actual != page) throw const HongguoRankingFormat();
    identified = true;
  }
  if (!identified) throw const HongguoRankingIncomplete();
  final List<html_dom.Element> pagination =
      document.querySelectorAll('nav[aria-label="榜单分页"]');
  if (pagination.length != 1) throw const HongguoRankingIncomplete();
  final List<html_dom.Element> current =
      pagination.first.querySelectorAll('[aria-current="page"]');
  if (current.length != 1 || current.first.text.trim() != page.toString()) {
    throw const HongguoRankingFormat();
  }
  bool hasMore = false;
  int maximumPage = page;
  for (final html_dom.Element link in pagination.first.querySelectorAll('a')) {
    final int? actual = _rankingUrlPage(link.attributes['href'] ?? '', board);
    if (actual == null) throw const HongguoRankingFormat();
    if (actual > maximumPage) maximumPage = actual;
    if (link.attributes['rel'] == 'next') {
      if (actual != page + 1) throw const HongguoRankingFormat();
      hasMore = true;
    }
  }
  final int totalPages = hasMore ? maximumPage : page;
  if (!hasMore && maximumPage != page) throw const HongguoRankingFormat();
  List<HongguoRankingItem> items = _rankingFromJsonLd(body, board, page);
  if (items.isEmpty) {
    for (final html_dom.Element list
        in document.querySelectorAll('ol[aria-label]')) {
      final List<html_dom.Element> articles = list
          .querySelectorAll('article')
          .where((html_dom.Element article) =>
              (article.attributes['aria-labelledby'] ?? '')
                  .startsWith('rank-title-'))
          .toList();
      if (articles.isEmpty) continue;
      if (items.isNotEmpty || articles.length > 20)
        throw const HongguoRankingFormat();
      for (final html_dom.Element article in articles) {
        final HongguoRankingItem? item = _rankingFromArticle(article);
        if (item == null) throw const HongguoRankingIncomplete();
        items.add(item);
      }
    }
  }
  if (items.isEmpty) throw const HongguoRankingIncomplete();
  final Set<String> seen = <String>{};
  int previous = (page - 1) * 20;
  for (final HongguoRankingItem item in items) {
    if (!hongguoNumericId.hasMatch(item.drama.sourceId) ||
        item.drama.title.isEmpty ||
        item.rank <= previous ||
        item.rank > page * 20 ||
        !seen.add(item.drama.sourceId)) {
      throw const HongguoRankingFormat();
    }
    previous = item.rank;
  }
  if (hasMore && items.length != 20) throw const HongguoRankingIncomplete();
  return HongguoRankingPage(
    items: items,
    hasMore: hasMore,
    totalPages: totalPages,
    updatedText: hongguoMapString(loader, <String>['updatedText']),
  );
}

int? _rankingUrlPage(String address, HongguoRankingBoard board) {
  final Uri? parsed = Uri.tryParse(address);
  if (parsed == null || parsed.hasAuthority && parsed.userInfo.isNotEmpty)
    return null;
  if (parsed.path.replaceAll(RegExp(r'/$'), '') != '/rank/${board.path}')
    return null;
  if (parsed.host.isNotEmpty &&
      parsed.host != 'hongguoduanju.com' &&
      parsed.host != 'www.hongguoduanju.com') {
    return null;
  }
  final String value = parsed.queryParameters['page'] ?? '';
  if (value.isEmpty) return 1;
  final int? page = int.tryParse(value);
  return page != null && page >= 1 && page <= 500 ? page : null;
}

String _rankingDramaId(String address) {
  final Uri? parsed = Uri.tryParse(address);
  if (parsed == null || parsed.path != '/detail') return '';
  if (parsed.host.isNotEmpty &&
      parsed.host != 'hongguoduanju.com' &&
      parsed.host != 'www.hongguoduanju.com') {
    return '';
  }
  return parsed.queryParameters['series_id'] ?? '';
}

List<HongguoRankingItem> _rankingFromJsonLd(
    String body, HongguoRankingBoard board, int page) {
  for (final RegExpMatch match in _jsonLdPattern.allMatches(body)) {
    final String raw = match.group(1) ?? '';
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) continue;
      final Map<String, dynamic> value = decoded.cast<String, dynamic>();
      if (value['@type'] != 'ItemList') continue;
      final int? actual = _rankingUrlPage(value['url'] as String? ?? '', board);
      final Object? elements = value['itemListElement'];
      if (actual != page ||
          elements is! List ||
          elements.isEmpty ||
          elements.length > 20) continue;
      final List<HongguoRankingItem> items = <HongguoRankingItem>[];
      for (final Object? row in elements) {
        if (row is! Map) continue;
        final Map<String, dynamic> map = row.cast<String, dynamic>();
        final String id = _rankingDramaId(map['url'] as String? ?? '');
        final String title = (map['name'] as String? ?? '').trim();
        final int position =
            map['position'] is num ? (map['position'] as num).toInt() : 0;
        items.add(HongguoRankingItem(
          rank: position,
          drama: HongguoDrama(
              id: HongguoDrama.dramaId(id), sourceId: id, title: title),
        ));
      }
      return items;
    } on Object {
      continue;
    }
  }
  return <HongguoRankingItem>[];
}

HongguoRankingItem? _rankingFromArticle(html_dom.Element article) {
  final String label = article.attributes['aria-labelledby'] ?? '';
  final String id = label.startsWith('rank-title-')
      ? label.substring('rank-title-'.length)
      : '';
  if (!hongguoNumericId.hasMatch(id)) return null;
  final List<html_dom.Element> headings = article
      .querySelectorAll('h2, h3')
      .where((html_dom.Element heading) => heading.attributes['id'] == label)
      .toList();
  if (headings.length != 1 || headings.first.parent == null) return null;
  final html_dom.Element? parent = headings.first.parent;
  if (parent is! html_dom.Element ||
      _rankingDramaId(parent.attributes['href'] ?? '') != id) return null;
  final String title = headings.first.text.trim();
  if (title.isEmpty || title.runes.length > 200) return null;
  String cover = '';
  String heat = '';
  String score = '';
  int rank = 0;
  for (final html_dom.Element link in article.querySelectorAll('a')) {
    if (!(link.attributes['aria-label'] ?? '').startsWith('查看')) continue;
    if (_rankingDramaId(link.attributes['href'] ?? '') != id) return null;
    final int? value = int.tryParse(link.text.trim());
    if (value != null && value > 0 && (rank == 0 || rank == value))
      rank = value;
    for (final html_dom.Element image in link.querySelectorAll('img')) {
      final String src = image.attributes['src'] ?? '';
      if (src.isNotEmpty) {
        cover = src;
        break;
      }
    }
  }
  for (final html_dom.Node node in article.querySelectorAll('*')) {
    if (node is html_dom.Element) {
      for (final html_dom.Node child in node.nodes) {
        if (child is html_dom.Text) {
          final String text = child.text.trim();
          if (_rankingMetric.hasMatch(text)) heat = text;
          if (text.startsWith('评分')) score = text.substring(2).trim();
        }
      }
    }
  }
  List<String> tags = <String>[];
  String intro = '';
  for (final html_dom.Element paragraph in article.querySelectorAll('p')) {
    final List<String> spans = <String>[];
    for (final html_dom.Node child in paragraph.nodes) {
      if (child is html_dom.Element &&
          child.localName == 'span' &&
          child.nodes.length == 1 &&
          child.nodes.first is html_dom.Text) {
        final String value = child.text.trim();
        if (value.isNotEmpty &&
            value.runes.length <= 20 &&
            !value.contains('热度')) {
          spans.add(value);
        }
      }
    }
    if (spans.isNotEmpty) {
      tags = spans;
    } else if (paragraph.nodes.length == 1 &&
        paragraph.nodes.first is html_dom.Text) {
      intro = paragraph.text.trim();
    }
  }
  if (rank <= 0) return null;
  return HongguoRankingItem(
    rank: rank,
    drama: HongguoDrama(
      id: HongguoDrama.dramaId(id),
      sourceId: id,
      title: title,
      cover: cover,
      intro: intro,
      categoryName: tags.isNotEmpty ? tags.first : '',
      tags: tags,
      score: score,
      heat: heat,
    ),
    metric: heat,
  );
}
