/// 红果发现服务：分类、排行、搜索、联想、推荐、详情的统一入口。
///
/// 发现链路以网页线为主：App 接口因签名缺项阻塞（见 hongguo_signing.dart），
/// 服务层先走网页线，App 详情仅在负缓存窗口外才尝试（失败即回落网页）。
/// 搜索沿用 Go `fetchHongguoSearch` 的双路合并：联想名称检索 + 搜索页，
/// 按标题匹配等级排序，并补齐多季（对应 `completeHongguoSearchSeasons` 的
/// 思路：对带季后缀的标题再查同名其他季）。
library;

import 'package:wxyy/core/hongguo/hongguo_app_client.dart';
import 'package:wxyy/core/hongguo/hongguo_models.dart';
import 'package:wxyy/core/hongguo/hongguo_ranking.dart';
import 'package:wxyy/core/hongguo/hongguo_web_client.dart';

/// 搜索结果。
class HongguoSearchResult {
  const HongguoSearchResult({
    required this.dramas,
    required this.total,
    required this.limited,
    this.warning = '',
  });

  final List<HongguoDrama> dramas;
  final int total;
  final bool limited;
  final String warning;
}

/// 红果发现服务。
class HongguoDiscoverService {
  HongguoDiscoverService(
      {HongguoWebClient? webClient, HongguoAppClient? appClient})
      : _web = webClient ?? HongguoWebClient(),
        _app = appClient ?? HongguoAppClient();

  final HongguoWebClient _web;
  final HongguoAppClient _app;

  /// 网页分类：四个路由的第一页（真人剧/漫剧/AI剧/动漫）。
  Future<List<HongguoDrama>> fetchWebDramas({int maxPagesPerRoute = 1}) =>
      _web.fetchWebDramas(maxPagesPerRoute: maxPagesPerRoute);

  /// 单个网页分类的一页。
  Future<({List<HongguoDrama> dramas, int totalPages})> fetchCategoryPage(
    String route,
    String category, {
    int page = 1,
  }) =>
      _web.fetchCategoryPage(route, category, page: page);

  /// 榜单页。
  Future<HongguoRankingPage> fetchRanking(
          HongguoRankingBoard board, int page) =>
      _web.fetchRankingPage(board, page);

  /// 搜索联想词条（最多 10 条，2 分钟内调用方自行缓存）。
  Future<List<HongguoSuggestion>> fetchSuggestions(String query) async {
    final String keyword = validateHongguoSearchKeyword(query);
    final List<HongguoSuggestionRecord> records =
        await _web.fetchSuggestionRecords(keyword, 10);
    return hongguoSuggestionsFromRecords(records);
  }

  /// 搜索：联想名称检索 + 搜索页双路合并，按标题匹配等级排序。
  Future<HongguoSearchResult> search(String keyword) async {
    final String query = validateHongguoSearchKeyword(keyword);
    List<HongguoDrama> names = <HongguoDrama>[];
    Object? namesError;
    try {
      final List<HongguoSuggestionRecord> records =
          await _web.fetchSuggestionRecords(query, 50);
      for (final HongguoSuggestionRecord record in records) {
        if (record.wordType != 'short_play_name') continue;
        final String seriesId = hongguoMapString(
            record.videoData, <String>['series_id_str', 'series_id']);
        if (!hongguoNumericId.hasMatch(seriesId)) continue;
        final HongguoDrama? drama = hongguoDramaFromAny(
          <String, dynamic>{
            'video_data': record.videoData,
            'name': record.name,
            'keyword': record.keyword
          },
          '短剧',
        );
        if (drama != null && drama.title != drama.sourceId) names.add(drama);
      }
    } on Object catch (error) {
      namesError = error;
    }
    List<HongguoDrama> pageDramas = <HongguoDrama>[];
    int total = 0;
    bool limited = false;
    Object? pageError;
    try {
      final ({List<HongguoDrama> dramas, int total, bool limited}) page =
          await _web.fetchSearchPage(query);
      pageDramas = page.dramas;
      total = page.total;
      limited = page.limited;
    } on Object catch (error) {
      pageError = error;
    }
    if (pageDramas.isEmpty &&
        names.isEmpty &&
        (pageError != null || namesError != null)) {
      throw HongguoSearchException('红果搜索失败：${pageError ?? namesError}');
    }
    final Map<String, HongguoDrama> merged = <String, HongguoDrama>{};
    for (final HongguoDrama drama in <HongguoDrama>[...pageDramas, ...names]) {
      merged[drama.id] = drama;
    }
    final List<HongguoDrama> dramas = merged.values.toList();
    dramas.sort((HongguoDrama a, HongguoDrama b) {
      final int rankA = hongguoTitleSearchRank(a.title, query);
      final int rankB = hongguoTitleSearchRank(b.title, query);
      if (rankA != rankB) return rankA.compareTo(rankB);
      final HongguoSeriesInfo? infoA = hongguoSeriesInfo(a);
      final HongguoSeriesInfo? infoB = hongguoSeriesInfo(b);
      if (infoA != null &&
          infoB != null &&
          infoA.season > 0 &&
          infoB.season > 0 &&
          infoA.unit == infoB.unit &&
          infoA.key == infoB.key) {
        return infoA.season.compareTo(infoB.season);
      }
      return 0;
    });
    String warning = '';
    if (pageError != null) {
      warning = '红果综合搜索暂不可用，已保留名称匹配结果，可重试';
    } else if (namesError != null) {
      warning = '红果名称检索暂不可用，结果可能缺少部分剧集，可重试';
    }
    if (total < dramas.length) total = dramas.length;
    return HongguoSearchResult(
      dramas: dramas,
      total: total,
      limited: limited || pageError != null || namesError != null,
      warning: warning,
    );
  }

  /// 详情：优先 App 详情（负缓存窗口内跳过），失败回落网页详情。
  Future<HongguoDetail> fetchDetail(String seriesId) async {
    if (!hongguoNumericId.hasMatch(seriesId)) {
      throw const HongguoSearchException('红果剧集 ID 无效');
    }
    if (!_app.deviceState.playerSuspended) {
      try {
        return await _app.appDetail(seriesId);
      } on Object {
        // App 详情失败时回落网页详情，错误原因由网页结果决定。
      }
    }
    final ({String title, List<HongguoEpisode> episodes}) web =
        await _web.fetchWebChapters(seriesId);
    return HongguoDetail(
      drama: HongguoDrama(
        id: HongguoDrama.dramaId(seriesId),
        sourceId: seriesId,
        title: web.title,
      ),
      episodes: web.episodes,
    );
  }

  /// 推荐：网页分类首轮即推荐流（App 推荐流需签名，缺项）。
  ///
  /// 调用方按分类取 [fetchCategoryPage] 即可；本方法返回合并去重后的
  /// 推荐列表，供首页推荐流使用。
  Future<List<HongguoDrama>> fetchRecommendations() => fetchWebDramas();
}

class HongguoSearchException implements Exception {
  const HongguoSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}
