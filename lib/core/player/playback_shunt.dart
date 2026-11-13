/// 播放协议分流：播放地址在送解码之前的分类决策（纯逻辑，无 UI 依赖）。
///
/// 识别三类非视频内容（格式口径见 `tvbox_nonvideo_format.md` 记的壳侧约定，
/// 与魔蚁 / 火蚁TV 同款分流语义一致，只借设计、不搬对方代码）：
/// - `novel://{json}`：小说，JSON 含 `title` / `content`；
/// - `pics://url1&&url2`：图片 / 漫画，`&&` 分隔多图；
/// - 音频直链：去查询串 / 锚点后命中常见音频后缀。
///
/// 另认蜘蛛回的 `vod_tag`（`text` / `image`）作双认信号：有标签无协议
/// 载荷时不送视频解码，返回带原因的拦截决策，由调用方展示诚实错误，
/// 而不是把非视频内容交给解码器黑屏转圈。
///
/// 协议可能出现在地址任意位置（如蜘蛛选集名的 `阅读$novel://…` 形态经
/// `$` 切分后地址本身即协议串；详情 `vod_play_url` 未切分时也可能整段
/// 出现），因此按子串查找而非仅判开头。未命中任何非视频信号时一律回
/// [PlaybackKind.video]，原视频链路一点不受影响。
library;

import 'dart:convert';

/// 播放内容分类。
enum PlaybackKind {
  /// 普通视频：走原视频解码链路。
  video,

  /// 小说文本：进播放器内文本阅读，不送解码。
  novel,

  /// 图片 / 图集：进播放器内图片浏览，不送解码。
  pics,

  /// 音频：走音频链路（只解音频、不渲染视频画面）。
  audio,
}

/// 分流出的非视频内容载荷。
class ShuntedContent {
  const ShuntedContent({
    required this.kind,
    required this.title,
    this.text = '',
    this.urls = const <String>[],
    this.headers = const <String, String>{},
    required this.sourceUrl,
  });

  /// 内容分类（novel / pics / audio 三种之一）。
  final PlaybackKind kind;

  /// 展示标题（小说取 JSON 内 title，缺失时用调用方给的 fallback）。
  final String title;

  /// 小说正文（仅 [PlaybackKind.novel] 有）。
  final String text;

  /// 图片地址列（仅 [PlaybackKind.pics] 有；音频则为单条地址）。
  final List<String> urls;

  /// 取内容所需的请求头（图片防盗链 Referer / UA 等，原样透传）。
  final Map<String, String> headers;

  /// 命中分流的原始地址（调试与日志用）。
  final String sourceUrl;
}

/// 一次分流决策。
class PlaybackDecision {
  const PlaybackDecision._({
    required this.kind,
    this.content,
    this.blockedReason,
  });

  /// 视频：未命中任何非视频信号，走原链路。
  const PlaybackDecision.video() : this._(kind: PlaybackKind.video);

  /// 分流命中且载荷可用。
  PlaybackDecision.shunted(ShuntedContent content)
    : this._(kind: content.kind, content: content);

  /// 分流命中但载荷不可用（如协议在、正文缺）：拦截，不送解码。
  const PlaybackDecision.blocked(PlaybackKind kind, String reason)
    : this._(kind: kind, blockedReason: reason);

  final PlaybackKind kind;

  /// 可用载荷；视频决策与拦截决策为 null。
  final ShuntedContent? content;

  /// 拦截原因；仅拦截决策非空。
  final String? blockedReason;

  /// 是否命中非视频分流（含拦截）。
  bool get shunted => kind != PlaybackKind.video;

  /// 是否为拦截决策（命中信号但无可用载荷）。
  bool get blocked => blockedReason != null;
}

/// 音频后缀表（与魔蚁播放器音频判型同一批，另加 flac）。
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

/// 对一次播放请求做分流决策。
///
/// [url] 为待播地址（已解析直链 / 直链 / 本地路径均可）；[episodeId]
/// 为剧集 id（蜘蛛详情 id 可能连带协议串，一并搜）；[vodTag] 为蜘蛛
/// 回的 `vod_tag`（`text` / `image` 双认）；[headers] 为取流请求头，
/// 命中图片时原样带给图片加载；[fallbackTitle] 为小说 JSON 无标题时
/// 的展示标题。
PlaybackDecision classifyPlayback({
  required String url,
  String? episodeId,
  String? vodTag,
  Map<String, String>? headers,
  String? fallbackTitle,
}) {
  final Map<String, String> effectiveHeaders = headers ?? const <String, String>{};
  final List<String> candidates = <String>[
    url,
    if (episodeId != null && episodeId.isNotEmpty) episodeId,
  ];
  for (final String candidate in candidates) {
    final int novelIndex = candidate.indexOf('novel://');
    if (novelIndex >= 0) {
      final String payload =
          candidate.substring(novelIndex + 'novel://'.length).trim();
      return _novelDecision(
        payload,
        sourceUrl: candidate,
        headers: effectiveHeaders,
        fallbackTitle: fallbackTitle,
      );
    }
    final int picsIndex = candidate.indexOf('pics://');
    if (picsIndex >= 0) {
      final String payload =
          candidate.substring(picsIndex + 'pics://'.length).trim();
      return _picsDecision(
        payload,
        sourceUrl: candidate,
        headers: effectiveHeaders,
        fallbackTitle: fallbackTitle,
      );
    }
  }

  // vod_tag 双认：有标签无协议载荷时拦截，不送视频解码。
  final Set<String> tags = _tagTokens(vodTag);
  if (tags.contains('text')) {
    return const PlaybackDecision.blocked(
      PlaybackKind.novel,
      '未取到小说正文（只有 text 标签、没有 novel:// 内容）',
    );
  }
  if (tags.contains('image')) {
    return const PlaybackDecision.blocked(
      PlaybackKind.pics,
      '未取到图片地址（只有 image 标签、没有 pics:// 内容）',
    );
  }

  // 音频直链：去查询串 / 锚点后判后缀。
  final String trimmed = url.trim();
  if (trimmed.isNotEmpty && _isAudioUrl(trimmed)) {
    return PlaybackDecision.shunted(
      ShuntedContent(
        kind: PlaybackKind.audio,
        title: fallbackTitle ?? '',
        urls: <String>[trimmed],
        headers: effectiveHeaders,
        sourceUrl: trimmed,
      ),
    );
  }

  return const PlaybackDecision.video();
}

PlaybackDecision _novelDecision(
  String payload, {
  required String sourceUrl,
  required Map<String, String> headers,
  String? fallbackTitle,
}) {
  if (!payload.startsWith('{')) {
    return const PlaybackDecision.blocked(
      PlaybackKind.novel,
      '小说内容格式无法解析（novel:// 后不是 JSON）',
    );
  }
  try {
    final Object? decoded = jsonDecode(payload);
    if (decoded is Map) {
      final String title = decoded['title']?.toString() ?? '';
      final String text = decoded['content']?.toString() ?? '';
      if (text.isNotEmpty) {
        return PlaybackDecision.shunted(
          ShuntedContent(
            kind: PlaybackKind.novel,
            title: title.isNotEmpty ? title : (fallbackTitle ?? ''),
            text: text,
            headers: headers,
            sourceUrl: sourceUrl,
          ),
        );
      }
    }
  } on Object {
    return const PlaybackDecision.blocked(
      PlaybackKind.novel,
      '小说内容格式无法解析（novel:// 后 JSON 解析失败）',
    );
  }
  return const PlaybackDecision.blocked(
    PlaybackKind.novel,
    '小说正文为空',
  );
}

PlaybackDecision _picsDecision(
  String payload, {
  required String sourceUrl,
  required Map<String, String> headers,
  String? fallbackTitle,
}) {
  final List<String> urls = <String>[
    for (final String part in payload.split('&&'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
  if (urls.isEmpty) {
    return const PlaybackDecision.blocked(
      PlaybackKind.pics,
      '图片地址为空',
    );
  }
  return PlaybackDecision.shunted(
    ShuntedContent(
      kind: PlaybackKind.pics,
      title: fallbackTitle ?? '',
      urls: urls,
      headers: headers,
      sourceUrl: sourceUrl,
    ),
  );
}

/// `vod_tag` 分词：按逗号 / 分号 / 空白切，统一小写去空。
Set<String> _tagTokens(String? vodTag) {
  if (vodTag == null || vodTag.trim().isEmpty) return const <String>{};
  return vodTag
      .split(RegExp(r'[,;\s]+'))
      .map((String t) => t.trim().toLowerCase())
      .where((String t) => t.isNotEmpty)
      .toSet();
}

bool _isAudioUrl(String url) {
  var path = url;
  final int hash = path.indexOf('#');
  if (hash >= 0) path = path.substring(0, hash);
  final int query = path.indexOf('?');
  if (query >= 0) path = path.substring(0, query);
  final String lower = path.toLowerCase();
  for (final String ext in _audioExtensions) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}
