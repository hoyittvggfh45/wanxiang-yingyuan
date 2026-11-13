/// 听书进度适配器：复用影视的播放位置与已看设施，不另建存储。
///
/// 内容键口径与影视播放器一致：`contentId` 取 [MediaItem.id]，章节下标
/// 取过滤后章节列表的 0 起下标（见 [AudiobookChapter.index]）。
/// 两个管理器均由启动期 Provider 注入（见 splash_screen）；取不到时退化
/// 为「无进度」（读回 -1/0，写操作静默跳过），不让详情页/播放器崩溃。
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:wxyy/core/history/media_playback_position_manager.dart';
import 'package:wxyy/core/history/media_watched_manager.dart';

/// 听书进度读写适配器。
class AudiobookProgress {
  const AudiobookProgress({this.positions, this.watched});

  /// 播放位置管理器（最后收听章节 + 章内位置）；null = 未注入，读无记录。
  final MediaPlaybackPositionManager? positions;

  /// 已听集合管理器；null = 未注入，读无记录。
  final MediaWatchedManager? watched;

  /// 从当前 [BuildContext] 取两个管理器（取不到任一时对应字段为 null）。
  static AudiobookProgress of(BuildContext context) => AudiobookProgress(
        positions: _tryRead<MediaPlaybackPositionManager>(context),
        watched: _tryRead<MediaWatchedManager>(context),
      );

  static T? _tryRead<T>(BuildContext context) {
    try {
      return Provider.of<T>(context, listen: false);
    } on Object {
      return null;
    }
  }

  /// 续听章节下标；无记录返回 -1。
  int continueIndex(String contentId) =>
      positions?.getLastEpisode(contentId) ?? -1;

  /// 某章节的章内续听位置（毫秒）；无记录返回 0。
  int positionMs(String contentId, int index) =>
      positions?.getPosition(contentId, index) ?? 0;

  /// 保存某章节的章内位置（毫秒）。
  Future<void> savePosition(
    String contentId,
    int index,
    int positionMs,
  ) async {
    await positions?.savePosition(contentId, index, positionMs);
  }

  /// 某章节是否已听完（达到已看阈值时由播放器标记）。
  bool isRead(String contentId, int index) =>
      watched?.isWatched(contentId, index) ?? false;

  /// 已听章节数。
  int readCount(String contentId) => watched?.watchedCount(contentId) ?? 0;

  /// 已听章节下标升序列表。
  List<int> readIndices(String contentId) =>
      watched?.watchedList(contentId) ?? const <int>[];

  /// 幂等标记某章节已听（重复标记不会取消）。
  Future<void> markRead(String contentId, int index) async {
    await watched?.markWatched(contentId, index);
  }
}
