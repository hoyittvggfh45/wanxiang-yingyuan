/// 红果播放控制策略：纯逻辑，不碰播放器界面。
///
/// 底包播放器（VideoPlayerScreen + PlayerController）已有：倍速、选集/线
/// 路面板、睡眠定时（按分钟/按集数）、自动连播、方向设置、断点续播位
/// 置存储（MediaPlaybackPositionManager）、预加载队列（PreloadQueue）。
/// 本文件只补红果特有的部分：清晰度标签、跨季连播判定、解码兼容过滤
/// （移植自 Go `selectHongguoAppMedia` 的编码过滤）、续播键规则。
library;

import 'hongguo_models.dart';

/// 清晰度标签：按高度数字生成（720 → 720p）。
String hongguoQualityLabel(int quality) {
  if (quality <= 0) return '自动';
  return '${quality}p';
}

/// 倍速档位（红果播放控制常用档，与底包 setPlaybackSpeed 对接）。
const List<double> hongguoSpeedSteps = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 不兼容的编码：底包播放器播不了，取流时直接跳过
/// （对应 Go `selectHongguoAppMedia` 里的 bytevc2 过滤）。
bool hongguoIsIncompatibleCodec(String codecType, String gearDesKey) {
  final String codec = codecType.toLowerCase();
  if (codec == 'bytevc2') return true;
  return gearDesKey.toLowerCase().contains('bytevc2');
}

/// 优先编码：h264/avc1 在同清晰度下优先（对应 Go 的 quality++）。
bool hongguoIsPreferredCodec(String codecType) {
  final String codec = codecType.toLowerCase();
  return codec == 'h264' || codec == 'avc1';
}

/// 续播记录键：`hongguo:<seriesId>:<episodeIndex>`，与底包
/// MediaPlaybackPositionManager 的 contentId/集下标键规则对齐。
String hongguoResumeKey(String seriesId, int episodeIndex) =>
    'hongguo:$seriesId:$episodeIndex';

/// 下一集判定：当前集播完后，返回同剧下一集；已是最后一集返回 null。
HongguoEpisode? hongguoNextEpisode(
    List<HongguoEpisode> episodes, int currentIndex) {
  for (final HongguoEpisode episode in episodes) {
    if (episode.index == currentIndex + 1) return episode;
  }
  return null;
}

/// 跨季连播判定：当前剧播完后，在候选剧集里找下一季。
///
/// 用多季分组（hongguoSeriesEntries）：当前季的下一季即连播目标；
/// 没有下一季返回 null，调用方停止连播。
HongguoDrama? hongguoNextSeasonDrama(
  HongguoDrama current,
  int currentSeason,
  Iterable<HongguoDrama> candidates,
) {
  final List<HongguoSeriesEntry> entries =
      hongguoSeriesEntries(current, candidates);
  HongguoSeriesEntry? next;
  for (final HongguoSeriesEntry entry in entries) {
    if (entry.season == currentSeason + 1) {
      next = entry;
      break;
    }
  }
  return next?.drama;
}

/// 当前剧的季数（标题无季后缀时视为第 1 季）。
int hongguoCurrentSeason(HongguoDrama drama, {String? unit}) {
  return hongguoSeriesInfo(drama, unit: unit)?.season ?? 1;
}

/// 常驻进度条是否显示：播放器控制层隐藏时仍显示细进度条。
///
/// 底包 VideoPlayerScreen 已有常驻进度实现，本函数只提供红果侧的默认
/// 策略值（默认显示），供接线方读取，不直接改播放器。
const bool hongguoPersistentProgressDefault = true;
