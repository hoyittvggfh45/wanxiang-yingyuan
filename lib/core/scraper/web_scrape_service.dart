/// 网页爬取服务（浏览页 → 网页爬取）。
///
/// 基于统一 [HttpFetcher] 拉取 HTML，再用 [HtmlUtils] 按模式抽取内容。
/// 设计目标：把「抓取 + 解析」与 UI 隔离，使 browse_web_scrape_screen 只负责展示。
library;

import '../utils/html_utils.dart';
import 'http_fetcher.dart';

/// 爬取模式：影响抽取策略与结果展示形态。
enum ScrapeMode {
  general,
  novel,
  comic,
  video,
  article;
}

/// 通用链接条目（供 general 模式展示）。
class ScrapeLink {
  final String text;
  final String url;
  const ScrapeLink({required this.text, required this.url});
}

/// 爬到的一条视频地址：带来源标记，供打开路由区分内嵌页地址。
///
/// [fromIframe] 为真表示取自 `<iframe src>`（内嵌播放页）；为假表示
/// 取自 `<video>` / `<video><source>`（页面声明的视频地址）。
class ScrapedVideo {
  final String url;
  final bool fromIframe;
  const ScrapedVideo({required this.url, required this.fromIframe});
}

/// 爬取结果：按模式填充不同字段，UI 按需渲染。
///
/// [html] 是本次实际拉取到的页面原文：一键生成 py 时直接用它做结构
/// 探测依据，不再重新拉取首页。
class ScrapeResult {
  final String url;
  final String? pageTitle;
  final String html;
  final List<String> paragraphs;
  final List<String> imageUrls;
  final List<ScrapedVideo> videoUrls;
  final List<ScrapeLink> links;

  const ScrapeResult({
    required this.url,
    this.pageTitle,
    this.html = '',
    this.paragraphs = const <String>[],
    this.imageUrls = const <String>[],
    this.videoUrls = const <ScrapedVideo>[],
    this.links = const <ScrapeLink>[],
  });

  bool get isEmpty =>
      pageTitle == null &&
      paragraphs.isEmpty &&
      imageUrls.isEmpty &&
      videoUrls.isEmpty &&
      links.isEmpty;
}

/// 网页爬取服务——全应用单例。
class WebScrapeService {
  WebScrapeService._();

  static final WebScrapeService instance = WebScrapeService._();

  /// 抓取 [url] 并按 [mode] 抽取内容。
  ///
  /// 相对地址会自动基于 [url] 解析为绝对地址。命中验证特征时抛出
  /// [VerificationRequiredException]（由调用方决定重试或跳转验证页）。
  Future<ScrapeResult> scrape(String url, ScrapeMode mode) async {
    final html = await HttpFetcher.instance.getHtml(url);
    // 空页面不是「无结果」：HTTP 成功却返回空正文，说明响应被截断或
    // 站点根本没吐内容，必须当错误报出来，否则用户看到的只是空态，
    // 无法区分「网没通」与「页上真没东西」。
    if (html.trim().isEmpty) {
      throw Exception('服务器返回了空页面，无内容可爬：$url');
    }
    final base = Uri.tryParse(url);
    String? absolutize(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      final uri = Uri.tryParse(raw);
      if (uri == null) return null;
      final resolved = base != null ? base.resolveUri(uri) : uri;
      return resolved.toString();
    }

    final pageTitle = HtmlUtils.query(html, 'title');

    switch (mode) {
      case ScrapeMode.general:
        final links = HtmlUtils.elements(html, 'a')
            .map((e) => ScrapeLink(
                  text: e.text.trim(),
                  url: absolutize(e.attributes['href']) ?? '',
                ))
            .where((l) => l.url.isNotEmpty)
            .toList();
        return ScrapeResult(url: url, pageTitle: pageTitle, html: html, links: links);

      case ScrapeMode.novel:
      case ScrapeMode.article:
        final paragraphs = HtmlUtils.queryAll(html, 'p')
            .where((s) => s.trim().length > 1)
            .toList();
        final imageUrls = mode == ScrapeMode.article
            ? _extractImages(html)
                .map((s) => absolutize(s))
                .where((s) => s != null)
                .cast<String>()
                .toList()
            : const <String>[];
        return ScrapeResult(
          url: url,
          pageTitle: pageTitle,
          html: html,
          paragraphs: paragraphs,
          imageUrls: imageUrls,
        );

      case ScrapeMode.comic:
        final imageUrls = _extractImages(html)
            .map((s) => absolutize(s))
            .where((s) => s != null)
            .cast<String>()
            .toList();
        return ScrapeResult(url: url, pageTitle: pageTitle, html: html, imageUrls: imageUrls);

      case ScrapeMode.video:
        final videoUrls = _extractVideos(html)
            .map((ScrapedVideo v) {
              final String? resolved = absolutize(v.url);
              if (resolved == null) return null;
              return ScrapedVideo(url: resolved, fromIframe: v.fromIframe);
            })
            .where((ScrapedVideo? v) => v != null)
            .cast<ScrapedVideo>()
            .toList();
        return ScrapeResult(url: url, pageTitle: pageTitle, html: html, videoUrls: videoUrls);
    }
  }

  List<String> _extractImages(String html) => HtmlUtils.elements(html, 'img')
      .map((e) =>
          e.attributes['src'] ??
          e.attributes['data-src'] ??
          e.attributes['data-original'] ??
          '')
      .where((s) => s.isNotEmpty)
      .toList();

  List<ScrapedVideo> _extractVideos(String html) {
    final list = <ScrapedVideo>[];
    for (final e in HtmlUtils.elements(html, 'video')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) {
        list.add(ScrapedVideo(url: src, fromIframe: false));
      }
    }
    for (final e in HtmlUtils.elements(html, 'video source')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) {
        list.add(ScrapedVideo(url: src, fromIframe: false));
      }
    }
    for (final e in HtmlUtils.elements(html, 'iframe')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) {
        list.add(ScrapedVideo(url: src, fromIframe: true));
      }
    }
    // 兜底：多数视频站把流地址藏在 <script>/JSON 里，页面上根本没有
    // <video> 标签。直接在原文里扫流媒体直链（m3u8/mp4 等），否则
    // 视频模式对这类站永远是空结果。只认绝对地址与 // 协议相对地址，
    // 去重、上限 100 条，避免把页面噪音全捞进来。
    final seen = list.map((v) => v.url).toSet();
    final streamPattern = RegExp(
      r'''(?:https?:)?//[^\s"'<>\\]+\.(?:m3u8|mp4|m4v|mov|flv|mkv|avi|webm)(?:\?[^\s"'<>\\]*)?''',
      caseSensitive: false,
    );
    for (final m in streamPattern.allMatches(html)) {
      if (list.length >= 100) break;
      final candidate = m.group(0)!;
      if (seen.add(candidate)) {
        list.add(ScrapedVideo(url: candidate, fromIframe: false));
      }
    }
    return list;
  }
}
