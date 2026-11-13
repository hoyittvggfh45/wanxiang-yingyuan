/// 听书取数服务：章节列表与章节音频地址。
///
/// 路由复用规则引擎现有语义，不新增路由名（规则格式里没有 `audio` 路由，
/// 见回报的规则引擎调查结论）：
/// - 章节列表走 `chapters` 路由（漫画/小说同一条），取不到时回退 `episodes`
///   路由（部分源只声明了 episodes 选择器）；
/// - 章节音频地址走 `video` 路由（解析器回 [VideoResult] 直链，mpv 不区分
///   音视频，均可打开；音频直链经 [isAudioResult] 判定仅作展示参考）。
library;

import 'package:wxyy/core/audiobook/audiobook_models.dart';
import 'package:wxyy/core/models/episode.dart';
import 'package:wxyy/core/models/media_item.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';

/// 听书取数服务（无状态，调用方按需构造）。
class AudiobookService {
  const AudiobookService();

  /// 取某作品的章节列表。
  ///
  /// 先走 `chapters` 路由；抛错或返回空列表时再试一次 `episodes` 路由，
  /// 两次都空则返回空列表（调用方展示「暂无章节」，不抛错惊动用户）。
  /// `episodes` 回退抛错时吞掉，只保留第一次的结果语义：章节为空。
  Future<List<AudiobookChapter>> fetchChapters(
    MediaApiService service,
    PluginConfig source,
    MediaItem item,
  ) async {
    List<Episode> episodes = const <Episode>[];
    try {
      episodes = await service.fetchChapters(source, item.id);
    } on Object {
      episodes = const <Episode>[];
    }
    if (episodes.isEmpty) {
      try {
        final fallback = await service.fetchEpisodes(
          source,
          item.id,
          detailUrl: item.detailUrl,
        );
        if (fallback.isNotEmpty) episodes = fallback;
      } on Object {
        // 回退失败：保持空列表，由调用方展示空状态。
      }
    }
    return audiobookChaptersFromEpisodes(episodes);
  }

  /// 取某章节的音频播放地址（[VideoResult] 直链 + 请求头）。
  ///
  /// 地址为空时抛 [StateError]（调用方展示可重试的错误态，不静默跳过）。
  Future<VideoResult> fetchAudioUrl(
    MediaApiService service,
    PluginConfig source,
    Episode chapter,
  ) async {
    final result = await service.fetchVideoUrl(source, chapter.url);
    if (result.url.isEmpty) {
      throw StateError('取流结果为空');
    }
    return result;
  }
}
