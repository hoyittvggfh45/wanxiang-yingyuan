/// 红果网页客户端：不签名、可直接请求的网页线。
///
/// 移植自火蚁TV Go 核 `provider_hongguo.go`（分类/详情/网页取流）、
/// `provider_hongguo_search.go`（搜索页）、`provider_hongguo_suggestions.go`
/// （联想）、`provider_hongguo_web_fallback.go`（游客会话兜底）与
/// `provider_rankings_hongguo.go`（榜单）。
///
/// 这是当前唯一可通的取流/发现链路：App 接口因签名密钥未移植而阻塞
/// （见 hongguo_signing.dart），网页线不依赖签名。
library;

import 'dart:convert';

import 'hongguo_http.dart';
import 'hongguo_models.dart';
import 'hongguo_playback_codec.dart';
import 'hongguo_ranking.dart';

/// 红果网页站根地址。
const String hongguoWebBaseUrl = 'https://hongguoduanju.com';

/// 网页游客会话有效期（对应 Go `hongguoWebSessionTTL`）。
const Duration hongguoWebSessionTtl = Duration(minutes: 25);

/// 网页兜底媒体缓存有效期与上限（对应 Go `hongguoWebMediaCacheTTL/Max`）。
const Duration hongguoWebMediaCacheTtl = Duration(minutes: 50);
const int hongguoWebMediaCacheMax = 300;

/// 公开 mp4 探活的最小体积（对应 Go `hongguoWebPublicMinBytes`）。
const int hongguoWebPublicMinBytes = 65536;

const String _webUserAgent =
    'Mozilla/5.0 (Linux; Android 16; SGT-AL10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

/// 网页分类路由（对应 Go `fetchHongguoWebDramas` 的 routes）。
const List<({String path, String name})> hongguoWebRoutes =
    <({String path, String name})>[
  (path: 'real-drama', name: '真人剧'),
  (path: 'comic-drama', name: '漫剧'),
  (path: 'ai-drama', name: 'AI剧'),
  (path: 'comic', name: '动漫'),
];

class HongguoWebException implements Exception {
  const HongguoWebException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 网页兜底未对该集开放（游客额度用尽或未对未登录访客开放）。
class HongguoWebFallbackUnavailable extends HongguoWebException {
  const HongguoWebFallbackUnavailable([super.message = '红果网页兜底未对该集开放']);
}

class _CachedMedia {
  const _CachedMedia({required this.url, required this.expiresAt});

  final String url;
  final DateTime expiresAt;
}

/// 红果网页客户端。
class HongguoWebClient {
  HongguoWebClient({HongguoTransport? transport})
      : _transport = transport ?? HongguoHttpTransport();

  final HongguoTransport _transport;
  String _sessionCookie = '';
  DateTime? _sessionFetchedAt;
  final Map<String, _CachedMedia> _mediaCache = <String, _CachedMedia>{};

  Map<String, String> _htmlHeaders() => <String, String>{
        'User-Agent': _webUserAgent,
        'Accept': 'text/html,application/xhtml+xml,application/json,*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': '$hongguoWebBaseUrl/',
      };

  Future<String> _fetchText(Uri uri,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final HongguoHttpResponse response =
        await _transport.get(uri, headers: _htmlHeaders()).timeout(timeout);
    if (response.statusCode != 200) {
      throw HongguoWebException('红果网页请求失败（HTTP ${response.statusCode}）');
    }
    return response.body;
  }

  /// 拉取一个分类的一页（对应 Go `fetchHongguoCategoryPage`）。
  ///
  /// 返回（本页剧集，总页数）。
  Future<({List<HongguoDrama> dramas, int totalPages})> fetchCategoryPage(
    String route,
    String category, {
    int page = 1,
  }) async {
    final String body = await _fetchText(
      Uri.parse('$hongguoWebBaseUrl/category/$route?page=$page'),
    );
    final Map<String, dynamic> pageData = hongguoRouterLoaderMap(
      parseHongguoRouterData(body),
      <String>['category_page', r'category_$'],
    );
    if (pageData.isEmpty || pageData['isSuccess'] == false) {
      throw const HongguoWebException('红果分类数据不可用，可能是页面结构或访问权限变化');
    }
    final List<HongguoDrama> out = <HongguoDrama>[];
    for (final Object? item in hongguoAnyList(pageData['recommendList'])) {
      final HongguoDrama? drama = hongguoDramaFromAny(item, category);
      if (drama != null) out.add(drama);
    }
    final int pages = int.tryParse(hongguoMapString(
          hongguoNestedMap(pageData, <String>['pagination']),
          <String>['totalPages'],
        )) ??
        1;
    return (dramas: out, totalPages: pages);
  }

  /// 拉取全部网页分类的第一页并去重（对应 Go `fetchHongguoWebDramas` 的首轮）。
  Future<List<HongguoDrama>> fetchWebDramas({int maxPagesPerRoute = 1}) async {
    final List<HongguoDrama> out = <HongguoDrama>[];
    final Set<String> seen = <String>{};
    final List<Object> failures = <Object>[];
    for (final ({String path, String name}) route in hongguoWebRoutes) {
      try {
        for (int page = 1; page <= maxPagesPerRoute; page++) {
          final ({List<HongguoDrama> dramas, int totalPages}) result =
              await fetchCategoryPage(route.path, route.name, page: page);
          int added = 0;
          for (final HongguoDrama drama in result.dramas) {
            if (seen.add(drama.id)) {
              out.add(drama);
              added++;
            }
          }
          if (added == 0 ||
              result.dramas.length < 24 ||
              page >= result.totalPages) break;
        }
      } on Object catch (error) {
        failures.add(error);
      }
    }
    if (out.isEmpty && failures.isNotEmpty) {
      throw HongguoWebException('红果网页分类全部失败：${failures.first}');
    }
    out.sort((HongguoDrama a, HongguoDrama b) => a.title.compareTo(b.title));
    return out;
  }

  /// 网页详情：标题 + 分集列表（对应 Go `fetchHongguoWebChapters`）。
  Future<({String title, List<HongguoEpisode> episodes})> fetchWebChapters(
      String seriesId) async {
    final String body = await _fetchText(
      Uri.parse(
          '$hongguoWebBaseUrl/detail?series_id=${Uri.encodeQueryComponent(seriesId)}'),
    );
    final Map<String, dynamic> pageData = hongguoRouterLoaderMap(
      parseHongguoRouterData(body),
      <String>['detail_page', 'detail_'],
    );
    final Map<String, dynamic> detail =
        hongguoNestedMap(pageData, <String>['seriesDetail']);
    if (detail.isEmpty) {
      throw const HongguoWebException('红果详情为空');
    }
    final String title = hongguoMapString(
        detail, <String>['series_name', 'series_title', 'name']);
    final List<HongguoEpisode> chapters = <HongguoEpisode>[];
    final List<dynamic> vids = hongguoAnyList(detail['vid_list']);
    for (int i = 0; i < vids.length; i++) {
      final String vid = vids[i].toString().trim();
      if (vid.isEmpty || vid == 'null') continue;
      final int index = i + 1;
      chapters.add(HongguoEpisode(
        id: 'hongguo:$seriesId:$vid',
        videoId: vid,
        index: index,
        title: '第$index集',
      ));
    }
    if (chapters.isEmpty) {
      throw const HongguoWebException('红果详情没有返回剧集 ID');
    }
    return (title: title.isEmpty ? seriesId : title, episodes: chapters);
  }

  /// 网页搜索页（对应 Go `fetchHongguoSearchPage`）。
  Future<({List<HongguoDrama> dramas, int total, bool limited})>
      fetchSearchPage(String keyword) async {
    final String body = await _fetchText(
      Uri.parse('$hongguoWebBaseUrl/search/${Uri.encodeComponent(keyword)}'),
      timeout: const Duration(seconds: 12),
    );
    final Map<String, dynamic> pageData = hongguoRouterLoaderMap(
      parseHongguoRouterData(body),
      <String>['search_(keyword)/page', 'search_'],
    );
    final Object? rowsRaw = pageData['searchList'];
    if (pageData['isSuccess'] != true ||
        rowsRaw is! List ||
        hongguoMapString(pageData, <String>['query']) != keyword) {
      throw const HongguoWebException('红果搜索未返回有效结果');
    }
    final List<HongguoDrama> dramas = <HongguoDrama>[];
    final Set<String> seen = <String>{};
    for (final Object? row in rowsRaw) {
      if (hongguoNestedMap(row, <String>['video_data']).isEmpty) continue;
      final HongguoDrama? drama = hongguoDramaFromAny(row, '短剧');
      if (drama != null && seen.add(drama.id)) dramas.add(drama);
    }
    if (rowsRaw.isNotEmpty && dramas.isEmpty) {
      throw const HongguoWebException('红果搜索结果中没有可识别的剧集');
    }
    int total =
        int.tryParse(hongguoMapString(pageData, <String>['totalCount'])) ?? 0;
    if (total < dramas.length) total = dramas.length;
    return (dramas: dramas, total: total, limited: total > dramas.length);
  }

  /// 搜索联想记录（对应 Go `fetchHongguoSuggestionRecords`）。
  Future<List<HongguoSuggestionRecord>> fetchSuggestionRecords(
      String query, int count) async {
    final Uri uri =
        Uri.parse('$hongguoWebBaseUrl/incent_resource/suggestion').replace(
      queryParameters: <String, String>{
        'app_id': '8662',
        'query': query,
        'count': count.toString(),
      },
    );
    final HongguoHttpResponse response =
        await _transport.get(uri, headers: <String, String>{
      'User-Agent': _webUserAgent,
      'Referer': '$hongguoWebBaseUrl/',
      'Accept': 'application/json',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    }).timeout(const Duration(seconds: 5));
    if (response.body.length > 256 * 1024) {
      throw const HongguoWebException('红果搜索联想响应过大');
    }
    if (response.statusCode != 200) {
      throw HongguoWebException('红果搜索联想请求失败（HTTP ${response.statusCode}）');
    }
    return parseHongguoSuggestionRecords(response.body);
  }

  /// 榜单页：3 次重试 + 平方退避（对应 Go `fetchHongguoRankingPage`）。
  Future<HongguoRankingPage> fetchRankingPage(
      HongguoRankingBoard board, int page) async {
    Object? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
            Duration(milliseconds: attempt * attempt * 300));
      }
      try {
        final String address =
            '$hongguoWebBaseUrl/rank/${board.path}${page > 1 ? '?page=$page' : ''}';
        final String body = await _fetchText(Uri.parse(address),
            timeout: const Duration(seconds: 18));
        return parseHongguoRanking(body, board, page);
      } on HongguoRankingIncomplete catch (error) {
        lastError = error;
      }
    }
    throw HongguoWebException('红果榜单加载失败：$lastError');
  }

  /// 网页播放页取流（对应 Go `resolveHongguoWebMedia`）。
  Future<HongguoMedia> resolveWebMedia(String seriesId, String videoId) async {
    final String body = await _fetchText(
      Uri.parse(
          '$hongguoWebBaseUrl/player/${Uri.encodeComponent(seriesId)}/${Uri.encodeComponent(videoId)}'),
    );
    final Map<String, dynamic> pageData = hongguoRouterLoaderMap(
      parseHongguoRouterData(body),
      <String>['player_', 'player_page'],
    );
    if (hongguoMapString(pageData, <String>['vid']) != videoId ||
        hongguoMapString(pageData, <String>['series_id']) != seriesId) {
      throw const HongguoWebException('红果未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限');
    }
    final Map<String, dynamic> info =
        hongguoNestedMap(pageData, <String>['video_player_info']);
    final List<String> addresses = hongguoMediaAddresses(
      info,
      isMediaUrl: hongguoIsMediaUrl,
      tryBase64Decode: hongguoTryBase64DecodeText,
    );
    if (addresses.isEmpty) {
      throw const HongguoWebException(
          '红果该集未提供公开播放地址，可能需要登录或 App 授权；不会将试看集冒充该集下载');
    }
    final double durationSeconds =
        double.tryParse(hongguoMapString(info, <String>['duration'])) ?? 0;
    final HongguoMedia media = HongguoMedia(
      url: addresses.first,
      referer: '$hongguoWebBaseUrl/',
      duration: Duration(milliseconds: (durationSeconds * 1000).round()),
      seriesId: seriesId,
      videoId: videoId,
    );
    return media.copyWith(
      variants: addresses
          .map((String address) =>
              media.copyWith(url: address, variants: const <HongguoMedia>[]))
          .toList(),
    );
  }

  /// 网页兜底取流：ttwid 游客会话 + fallback-play-info + 公开 mp4 探活
  /// （对应 Go `resolveHongguoWebFallback`）。
  Future<HongguoMedia> resolveWebFallback(
      String seriesId, String videoId) async {
    if (!hongguoNumericId.hasMatch(seriesId) ||
        !hongguoNumericId.hasMatch(videoId)) {
      throw const HongguoWebException('红果网页兜底缺少有效的剧集 ID');
    }
    final String key = '$seriesId|$videoId';
    final _CachedMedia? cached = _mediaCache[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return HongguoMedia(url: cached.url, referer: '$hongguoWebBaseUrl/');
    }
    Object? lastError;
    bool sawUnavailable = false;
    const List<String> definitions = <String>['720p', '480p', '360p', '720p'];
    for (int attempt = 0; attempt < definitions.length; attempt++) {
      String session;
      try {
        session = await _webSession(forceRefresh: attempt > 0);
      } on Object catch (error) {
        lastError = error;
        break;
      }
      try {
        final String? mediaUrl = await _webFallbackPost(
            seriesId, videoId, definitions[attempt], session);
        if (mediaUrl != null && mediaUrl.isNotEmpty) {
          _cacheMedia(key, mediaUrl);
          return HongguoMedia(url: mediaUrl, referer: '$hongguoWebBaseUrl/');
        }
      } on HongguoWebFallbackUnavailable catch (error) {
        lastError = error;
        sawUnavailable = true;
      } on Object catch (error) {
        lastError = error;
      }
      _discardSession();
    }
    for (final String definition in <String>['720p', '480p', '360p']) {
      final String publicUrl =
          '$hongguoWebBaseUrl/video/public/$videoId/$definition.mp4';
      try {
        if (await _publicAvailable(publicUrl)) {
          _cacheMedia(key, publicUrl);
          return HongguoMedia(url: publicUrl, referer: '$hongguoWebBaseUrl/');
        }
      } on Object catch (error) {
        lastError = error;
      }
    }
    if (sawUnavailable) {
      throw HongguoWebException('红果网页兜底未对该集开放：游客会话额度用尽或该集未对未登录访客开放：$lastError');
    }
    if (lastError != null) {
      throw HongguoWebException('红果网页兜底未返回该集播放地址：$lastError');
    }
    throw const HongguoWebException('红果网页兜底未返回该集播放地址');
  }

  Future<String> _webSession({required bool forceRefresh}) async {
    if (!forceRefresh &&
        _sessionCookie.isNotEmpty &&
        _sessionFetchedAt != null &&
        DateTime.now().difference(_sessionFetchedAt!) < hongguoWebSessionTtl) {
      return _sessionCookie;
    }
    final HongguoHttpResponse response = await _transport
        .get(Uri.parse('$hongguoWebBaseUrl/'), headers: _htmlHeaders())
        .timeout(const Duration(seconds: 20));
    final String? ttwid = response.cookies['ttwid'];
    if (ttwid == null || ttwid.isEmpty) {
      throw const HongguoWebException('红果网页游客会话不可用');
    }
    _sessionCookie = 'ttwid=$ttwid';
    _sessionFetchedAt = DateTime.now();
    return _sessionCookie;
  }

  Future<String?> _webFallbackPost(String seriesId, String videoId,
      String definition, String session) async {
    final List<int> payload = utf8.encode(jsonEncode(<String, String>{
      'series_id': seriesId,
      'item_id': videoId,
      'definition': definition,
    }));
    final HongguoHttpResponse response = await _transport
        .post(
          Uri.parse(
              '$hongguoWebBaseUrl/api/video/protected/fallback-play-info'),
          headers: <String, String>{
            'User-Agent': _webUserAgent,
            'Accept': 'application/json',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            'Referer': '$hongguoWebBaseUrl/',
            'Origin': hongguoWebBaseUrl,
            'Content-Type': 'application/json',
            'Cookie': session,
          },
          body: payload,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      if (response.statusCode == 403)
        throw const HongguoWebFallbackUnavailable();
      throw HongguoWebException('红果网页兜底 HTTP ${response.statusCode}');
    }
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const HongguoWebException('红果网页兜底返回格式异常');
    }
    final Map<String, dynamic> result = decoded.cast<String, dynamic>();
    if (hongguoMapString(result, <String>['error']) ==
        'public_fallback_unavailable') {
      throw const HongguoWebFallbackUnavailable();
    }
    String address = hongguoMapString(result, <String>['main_url']);
    if (address.isNotEmpty && hongguoIsMediaUrl(address)) return address;
    final Map<String, dynamic> nested =
        hongguoNestedMap(result, <String>['data']);
    address = hongguoMapString(nested, <String>['main_url']);
    if (address.isNotEmpty && hongguoIsMediaUrl(address)) return address;
    throw const HongguoWebFallbackUnavailable();
  }

  Future<bool> _publicAvailable(String rawUrl) async {
    final HongguoHttpResponse response =
        await _transport.head(Uri.parse(rawUrl), headers: <String, String>{
      'User-Agent': _webUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': '$hongguoWebBaseUrl/',
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return false;
    return response.contentLength > hongguoWebPublicMinBytes;
  }

  void _cacheMedia(String key, String mediaUrl) {
    if (_mediaCache.length >= hongguoWebMediaCacheMax) _mediaCache.clear();
    _mediaCache[key] = _CachedMedia(
      url: mediaUrl,
      expiresAt: DateTime.now().add(hongguoWebMediaCacheTtl),
    );
  }

  void _discardSession() {
    _sessionCookie = '';
    _sessionFetchedAt = null;
  }
}
