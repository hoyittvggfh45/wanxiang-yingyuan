/// 分流内容视图：播放器内的文本阅读 / 图片浏览 / 拦截提示 / 音频封面。
///
/// 与播放器页、内嵌播放器、海阔播放页、RSS 内嵌播放器四处共用；
/// 只做内容展示，不碰解码与播放控制。图片加载用调用方透传的请求头
///（防盗链 Referer / UA），无头时不带头，不写死任何站点默认值。
library;

import 'package:material_ui/material_ui.dart';

import '../../../core/player/playback_shunt.dart';

/// 播放器内小说阅读视图：标题 + 字号调节 + 可滚动正文（可选中复制）。
class ShuntNovelView extends StatefulWidget {
  const ShuntNovelView({
    super.key,
    required this.content,
    required this.title,
  });

  final ShuntedContent content;
  final String title;

  @override
  State<ShuntNovelView> createState() => _ShuntNovelViewState();
}

class _ShuntNovelViewState extends State<ShuntNovelView> {
  double _fontSize = 17;

  @override
  Widget build(BuildContext context) {
    final String title =
        widget.content.title.isNotEmpty ? widget.content.title : widget.title;
    return Container(
      color: const Color(0xFFF7F1E3),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '减小字号',
                  onPressed: _fontSize > 13
                      ? () => setState(() => _fontSize -= 1)
                      : null,
                  icon: const Icon(Icons.text_decrease),
                ),
                Text(
                  '${_fontSize.toInt()}',
                  style: const TextStyle(color: Colors.black54),
                ),
                IconButton(
                  tooltip: '增大字号',
                  onPressed: _fontSize < 26
                      ? () => setState(() => _fontSize += 1)
                      : null,
                  icon: const Icon(Icons.text_increase),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
              child: SelectableText(
                widget.content.text,
                style: TextStyle(
                  fontSize: _fontSize,
                  height: 1.7,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 播放器内图片浏览视图：左右翻页 + 双指缩放 + 计数与上下张按钮。
class ShuntPicsView extends StatefulWidget {
  const ShuntPicsView({
    super.key,
    required this.content,
    required this.title,
  });

  final ShuntedContent content;
  final String title;

  @override
  State<ShuntPicsView> createState() => _ShuntPicsViewState();
}

class _ShuntPicsViewState extends State<ShuntPicsView> {
  late final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ShuntPicsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content.sourceUrl != widget.content.sourceUrl) {
      _index = 0;
      _controller.jumpToPage(0);
    }
  }

  Map<String, String>? get _headers =>
      widget.content.headers.isEmpty ? null : widget.content.headers;

  @override
  Widget build(BuildContext context) {
    final List<String> urls = widget.content.urls;
    return Container(
      color: Colors.black,
      child: Stack(
        children: <Widget>[
          PageView.builder(
            controller: _controller,
            itemCount: urls.length,
            onPageChanged: (int value) {
              setState(() => _index = value);
              for (final int next in <int>[value - 1, value + 1]) {
                if (next >= 0 && next < urls.length) {
                  precacheImage(
                    NetworkImage(urls[next], headers: _headers),
                    context,
                  );
                }
              }
            },
            itemBuilder: (BuildContext context, int i) {
              return InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.network(
                    urls[i],
                    headers: _headers,
                    fit: BoxFit.contain,
                    loadingBuilder: (
                      BuildContext context,
                      Widget child,
                      ImageChunkEvent? progress,
                    ) {
                      if (progress == null) return child;
                      return const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      );
                    },
                    errorBuilder: (BuildContext context, Object _, StackTrace? __) =>
                        Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '图片加载失败\n${urls[i]}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton(
                  tooltip: '上一张',
                  onPressed: _index > 0
                      ? () => _controller.previousPage(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                          )
                      : null,
                  icon: const Icon(Icons.chevron_left, color: Colors.white),
                ),
                Text(
                  '${_index + 1} / ${urls.length}',
                  style: const TextStyle(color: Colors.white),
                ),
                IconButton(
                  tooltip: '下一张',
                  onPressed: _index + 1 < urls.length
                      ? () => _controller.nextPage(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                          )
                      : null,
                  icon: const Icon(Icons.chevron_right, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 分流拦截提示：命中非视频信号但载荷不可用时的诚实错误态。
class ShuntBlockedView extends StatelessWidget {
  const ShuntBlockedView({
    super.key,
    required this.reason,
    this.onRetry,
  });

  final String reason;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.info_outline_rounded,
              color: Colors.white70,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 音频模式封面区：替代视频画面，播放控制仍由所在播放器的控制层负责。
class ShuntAudioCover extends StatelessWidget {
  const ShuntAudioCover({
    super.key,
    required this.title,
    this.coverUrl,
  });

  final String title;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final String? cover = coverUrl;
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: cover != null && cover.isNotEmpty
                  ? Image.network(
                      cover,
                      width: 180,
                      height: 180,
                      fit: BoxFit.cover,
                      errorBuilder:
                          (BuildContext context, Object _, StackTrace? __) =>
                              _fallbackArtwork(),
                    )
                  : _fallbackArtwork(),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.music_note_rounded, color: Colors.white54, size: 16),
                SizedBox(width: 4),
                Text('音频播放', style: TextStyle(color: Colors.white54)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackArtwork() {
    return Container(
      width: 180,
      height: 180,
      color: Colors.white12,
      child: const Icon(
        Icons.music_note_rounded,
        color: Colors.white54,
        size: 72,
      ),
    );
  }
}
