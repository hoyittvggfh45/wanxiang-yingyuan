/// 红果时间轴弹幕拉取器：按 30 秒窗口逐页拉取，合并为时间轴弹幕。
///
/// 移植自火蚁TV Go 核 `ui_playback_danmaku.go`（窗口分页、缓存）与
/// `provider_hongguo_app.go`（弹幕请求走文字签名分支）。
///
/// 未实现底包 [DanmakuSource] 接口：该接口的 [DanmakuSourceType] 枚举
/// 里没有红果类型，加枚举值超出本任务文件范围，需主执行人加值后由接
/// 线方用本拉取器包装。本拉取器直接返回底包的 [ParsedDanmakuItem]，
/// 接线时只需按集 ID 格式调用 [fetchAll]。
///
/// 集 ID 格式：`hongguo:<seriesId>:<videoId>:<durationMs>`。
library;

import 'package:material_ui/material_ui.dart';

import 'package:wxyy/core/danmaku/danmaku_source.dart';
import 'package:wxyy/core/hongguo/hongguo_app_client.dart';
import 'package:wxyy/core/hongguo/hongguo_models.dart';

/// 弹幕窗口大小：30 秒（对应 Go `danmakuWindowMS`）。
const int hongguoDanmakuWindowMs = 30000;

/// 单集最多拉取窗口数（防超长剧集无限请求；30 秒 × 120 = 60 分钟）。
const int hongguoDanmakuMaxWindows = 120;

/// 解析红果弹幕集 ID，格式不对返回 null。
({String seriesId, String videoId, int durationMs})?
    parseHongguoDanmakuEpisodeId(String episodeId) {
  final List<String> parts = episodeId.split(':');
  if (parts.length != 4 || parts[0] != 'hongguo') return null;
  final int? durationMs = int.tryParse(parts[3]);
  if (!hongguoNumericId.hasMatch(parts[1]) ||
      !hongguoNumericId.hasMatch(parts[2]) ||
      durationMs == null ||
      durationMs <= 0) {
    return null;
  }
  return (seriesId: parts[1], videoId: parts[2], durationMs: durationMs);
}

/// 构造红果弹幕集 ID。
String hongguoDanmakuEpisodeId(
        String seriesId, String videoId, int durationMs) =>
    'hongguo:$seriesId:$videoId:$durationMs';

/// 红果弹幕拉取器。
class HongguoDanmakuFetcher {
  HongguoDanmakuFetcher({HongguoAppClient? appClient})
      : _app = appClient ?? HongguoAppClient();

  final HongguoAppClient _app;

  /// 拉取一集的全部弹幕：从 0 开始按窗口推进，直到覆盖全集或达到上限。
  Future<List<ParsedDanmakuItem>> fetchAll(String episodeId) async {
    final ({String seriesId, String videoId, int durationMs})? ids =
        parseHongguoDanmakuEpisodeId(episodeId);
    if (ids == null) {
      throw const FormatException('红果弹幕集 ID 格式无效');
    }
    return fetchAllFor(ids.seriesId, ids.videoId, ids.durationMs);
  }

  /// 拉取一集的全部弹幕（直接给 ID 与时长）。
  Future<List<ParsedDanmakuItem>> fetchAllFor(
      String seriesId, String videoId, int durationMs) async {
    final List<ParsedDanmakuItem> out = <ParsedDanmakuItem>[];
    final Set<String> seen = <String>{};
    int start = 0;
    for (int window = 0;
        window < hongguoDanmakuMaxWindows && start < durationMs;
        window++) {
      final HongguoDanmakuPage page = await _app.danmakuPage(
        seriesId: seriesId,
        videoId: videoId,
        startMs: start,
        durationMs: durationMs,
      );
      for (final HongguoDanmakuItem item in page.items) {
        if (!seen.add(item.id)) continue;
        out.add(ParsedDanmakuItem(
          text: item.text,
          time: item.timeMs / 1000,
          color: Colors.white,
        ));
      }
      if (page.nextMs <= start) break;
      start = page.nextMs;
    }
    out.sort(
        (ParsedDanmakuItem a, ParsedDanmakuItem b) => a.time.compareTo(b.time));
    return out;
  }
}
