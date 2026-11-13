/// 听书章节模型与音频地址判定（纯 Dart，不依赖 Flutter widget 层）。
///
/// 章节复用统一的 [Episode] 结构承载（与漫画/小说章节同一做法，见
/// [MediaApiService.fetchChapters]）：解析器回 `chapters`/`episodes` 路由的
/// `List<Episode>`，本层只做过滤与序号整理，不再定义第二套章节结构。
library;

import 'package:wxyy/core/models/episode.dart';

/// 一章有声书：[Episode] + 在过滤后列表中的位置。
///
/// [index] 为 0 起的下标，与进度管理器（播放位置管理器 /
/// 已看管理器）的 `episodeIndex` 口径一致：详情页、播放器、
/// 进度三处共用同一套下标。
class AudiobookChapter {
  const AudiobookChapter({required this.index, required this.episode});

  /// 在过滤后章节列表中的下标（0 起）。
  final int index;

  /// 解析器返回的原始章节。
  final Episode episode;

  String get id => episode.id;

  /// 章节标题；源未给标题时按过滤后位置补「第 N 章」（N 从 1 起）。
  String get title =>
      episode.title.isEmpty ? '第 ${index + 1} 章' : episode.title;

  /// 章节页地址（取流时传给 `video` 路由的 `{url}`，不是最终音频直链）。
  String get url => episode.url;

  /// 播放线路名（源分线路时）；无线路的源为 null。
  String? get lineName => episode.lineName;

  /// 章节序号：源自带 [Episode.number] 优先，否则按过滤后位置补 1 起序号。
  int get number => episode.number ?? index + 1;
}

/// 解析结果 → 听书章节列表。
///
/// 过滤规则：丢弃 [Episode.url] 为空的条目（无地址的章节无法取流，留在
/// 列表里点开必定失败）；其余按原顺序保留，[AudiobookChapter.index] 按
/// 过滤后的位置重排，保证详情页、播放器、进度下标三处对齐。
List<AudiobookChapter> audiobookChaptersFromEpisodes(
  List<Episode> episodes,
) {
  final chapters = <AudiobookChapter>[];
  for (final episode in episodes) {
    if (episode.url.isEmpty) continue;
    chapters.add(
      AudiobookChapter(index: chapters.length, episode: episode),
    );
  }
  return chapters;
}

/// 音频文件扩展名集合（与嗅探器的音频判定、本地内容管理器的音频扩展名
/// 取并集，另加 opus）。
///
/// 仅用于「直链看起来是音频」的启发式判定：无扩展名的动态地址（如
/// `.../audio/123`）判定为未知，播放器仍会按直链尝试打开，不因此拦截。
const Set<String> audioFileExtensions = <String>{
  'mp3',
  'm4a',
  'aac',
  'ogg',
  'oga',
  'flac',
  'wav',
  'wma',
  'opus',
};

/// 取 URL 路径部分的扩展名（小写、无点号；剥离查询串与 fragment）。
///
/// 解析失败或无扩展名时返回 null。
String? _pathExtension(String url) {
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  final path = (uri?.path ?? url).toLowerCase();
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  final slash = path.lastIndexOf('/');
  if (slash > dot) return null;
  final ext = path.substring(dot + 1);
  if (ext.isEmpty || ext.contains('?') || ext.contains('#')) return null;
  return ext;
}

/// 地址的路径扩展名是否属于音频扩展名。
///
/// `.m3u8` 返回 false：HLS 可能是纯音频也可能是视频，URL 本身无法区分，
/// 播放器按流媒体打开即可，不由本判定分流。
bool isAudioUrl(String url) {
  final ext = _pathExtension(url);
  return ext != null && audioFileExtensions.contains(ext);
}

/// 推断音频地址的类型（扩展名，如 `mp3`）；非音频地址返回 null。
String? inferAudioType(String url) {
  final ext = _pathExtension(url);
  if (ext == null || !audioFileExtensions.contains(ext)) return null;
  return ext;
}

/// 取流结果是否为音频。
///
/// 判定顺序：解析器显式标的 `type == 'audio'` 优先，其次看 URL 扩展名。
/// 结果为 false 不代表不能播（动态地址无扩展名时照常走播放器尝试）。
bool isAudioResult(VideoResult result) {
  if (result.type == 'audio') return true;
  return isAudioUrl(result.url);
}
