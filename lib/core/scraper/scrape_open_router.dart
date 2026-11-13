/// 爬取结果打开路由：决定爬到的内容走主链路的哪个去向（纯逻辑，无 UI 依赖）。
///
/// 视频地址：`<video>` / `<source>` 取出的地址由页面声明为视频，一律进
/// 主播放器直链模式（播不起来由播放器报真原因）；`<iframe>` 取出的地址
/// 只有本身看起来是媒体直链时才进播放器，否则走外部浏览器兜底——内嵌
/// 播放页硬塞播放器只会黑屏转圈。分流载荷构造器供小说 / 漫画模式复用
/// 播放器协议分流：正文拼 `novel://`、图列拼 `pics://`，经主播放器
/// 直链模式打开，分流视图接管展示，不新造阅读器。
library;

import 'dart:convert';

/// 爬取视频地址的打开去向。
enum ScrapeVideoRoute {
  /// 进主播放器直链模式（分流自动接管其中音频地址）。
  player,

  /// 外部浏览器打开（内嵌页等非媒体地址不硬塞播放器）。
  browser,

  /// 无法打开（空地址 / blob: / data: 等，调用方须报真原因）。
  unsupported,
}

/// 视频直链后缀表（去查询串 / 锚点后判，与分流音频表互补）。
const List<String> _videoExtensions = <String>[
  '.mp4',
  '.m4v',
  '.webm',
  '.mov',
  '.mkv',
  '.avi',
  '.flv',
  '.m3u8',
  '.mpd',
  '.ts',
  '.3gp',
  '.wmv',
];

/// 音频直链后缀表（与分流 `playback_shunt.dart` 的音频表同批；
/// 音频同样进主播放器，由分流换音频视图）。
const List<String> _audioExtensions = <String>[
  '.mp3',
  '.m4a',
  '.aac',
  '.opus',
  '.ogg',
  '.oga',
  '.wav',
  '.flac',
];

/// 判定一条爬取视频地址的打开去向。
///
/// [fromIframe] 为真表示该地址取自 `<iframe src>`（内嵌播放页）。
ScrapeVideoRoute classifyScrapeVideoUrl(
  String url, {
  required bool fromIframe,
}) {
  final String trimmed = url.trim();
  if (trimmed.isEmpty) return ScrapeVideoRoute.unsupported;
  final String lower = trimmed.toLowerCase();
  // 会话内 / 非网络地址无法在外部打开，也不进播放器。
  if (lower.startsWith('blob:') ||
      lower.startsWith('mediasource:') ||
      lower.startsWith('data:') ||
      lower.startsWith('javascript:') ||
      lower.startsWith('about:')) {
    return ScrapeVideoRoute.unsupported;
  }
  if (_looksLikeMediaUrl(lower)) return ScrapeVideoRoute.player;
  if (fromIframe) {
    // 内嵌页地址：只有 http(s) 才能交给外部浏览器。
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return ScrapeVideoRoute.browser;
    }
    return ScrapeVideoRoute.unsupported;
  }
  // <video> / <source> 声明的地址：一律进播放器，失败由播放器报真原因。
  return ScrapeVideoRoute.player;
}

bool _looksLikeMediaUrl(String lowerTrimmedUrl) {
  var path = lowerTrimmedUrl;
  final int hash = path.indexOf('#');
  if (hash >= 0) path = path.substring(0, hash);
  final int query = path.indexOf('?');
  if (query >= 0) path = path.substring(0, query);
  for (final String ext in _videoExtensions) {
    if (path.endsWith(ext)) return true;
  }
  for (final String ext in _audioExtensions) {
    if (path.endsWith(ext)) return true;
  }
  return false;
}

/// 拼小说分流载荷：`novel://{title,content}`，供主播放器分流接管。
///
/// [content] 为空时仍拼出载荷，分流会返回带原因的拦截决策，
/// 调用方展示诚实错误（不在此静默吞掉）。
String buildScrapeNovelPayload({
  required String title,
  required String content,
}) {
  return 'novel://${jsonEncode(<String, String>{
        'title': title,
        'content': content,
      })}';
}

/// 拼图片分流载荷：`pics://url1&&url2`，供主播放器分流接管。
///
/// 空地址先滤掉；全空时拼出空载荷，分流返回带原因的拦截决策。
String buildScrapePicsPayload(List<String> urls) {
  final List<String> kept = <String>[
    for (final String u in urls)
      if (u.trim().isNotEmpty) u.trim(),
  ];
  return 'pics://${kept.join('&&')}';
}
