/// 听书详情页：封面 + 标题/作者/状态/简介 + 续听按钮 + 章节列表。
///
/// 取数走 [AudiobookService]（`chapters`/`episodes` 路由取目录，`video`
/// 路由取流）；进度与历史复用 [AudiobookProgress] 与 [HistoryManager]。
/// 点章节进 [AudiobookPlayerScreen]；下载未接（下载设施无音频处理器，
/// 见回报），本页不设下载入口。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:wxyy/core/audiobook/audiobook_models.dart';
import 'package:wxyy/core/audiobook/audiobook_progress.dart';
import 'package:wxyy/core/audiobook/audiobook_service.dart';
import 'package:wxyy/core/history/history_manager.dart';
import 'package:wxyy/core/models/episode.dart';
import 'package:wxyy/core/models/media_item.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/navigation/app_page_route.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/theme/app_tokens.dart';
import 'package:wxyy/core/widgets/source_image.dart';
import 'package:wxyy/features/audiobook/presentation/audiobook_chapter_list.dart';
import 'package:wxyy/features/audiobook/presentation/audiobook_player_screen.dart';

/// 听书详情页。
class AudiobookDetailScreen extends StatefulWidget {
  const AudiobookDetailScreen({super.key, required this.item, this.heroTag});

  /// 列表项（至少含 id/title/sourceId；详情接口会再补全字段）。
  final MediaItem item;

  /// 封面 Hero 标记（列表页传入时共用转场）。
  final String? heroTag;

  @override
  State<AudiobookDetailScreen> createState() => _AudiobookDetailScreenState();
}

class _AudiobookDetailScreenState extends State<AudiobookDetailScreen> {
  static const AudiobookService _service = AudiobookService();

  PluginConfig? _source;
  MediaItem? _detail;
  List<AudiobookChapter> _chapters = const <AudiobookChapter>[];
  bool _loading = true;
  String? _error;
  bool _historyRecorded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final MediaApiService api = context.read<MediaApiService>();
    final SourceRepository repo = context.read<SourceRepository>();
    final PluginConfig? source = widget.item.sourceId == null
        ? null
        : repo.getById(widget.item.sourceId!);
    if (source == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '找不到该作品的源（源可能已被删除）';
      });
      return;
    }
    MediaItem detail = widget.item;
    try {
      detail = await api.fetchDetail(
        source,
        widget.item.id,
        detailUrl: widget.item.detailUrl,
      );
    } on Object {
      // 详情接口失败不致命：用列表项已有字段继续展示，章节照常取。
    }
    final List<AudiobookChapter> chapters =
        await _service.fetchChapters(api, source, detail);
    if (!mounted) return;
    setState(() {
      _source = source;
      _detail = detail;
      _chapters = chapters;
      _loading = false;
    });
    _recordHistory(detail);
  }

  void _recordHistory(MediaItem detail) {
    if (_historyRecorded) return;
    _historyRecorded = true;
    final HistoryManager history = context.read<HistoryManager>();
    // lastChapter 留空：播放器打开章节时会以当前章重记一次。
    unawaited(
      history.addHistory(detail, sourceType: SourceType.audioSource),
    );
  }

  void _openPlayer(int index) {
    final PluginConfig? source = _source;
    if (source == null || _chapters.isEmpty) return;
    if (index < 0 || index >= _chapters.length) return;
    final List<Episode> episodes =
        _chapters.map((AudiobookChapter c) => c.episode).toList();
    Navigator.of(context)
        .push(
      AppPageRoute<void>(
        builder: (_) => AudiobookPlayerScreen(
          source: source,
          item: _detail ?? widget.item,
          chapters: episodes,
          initialChapterIndex: index,
        ),
      ),
    )
        .then((_) {
      // 播放回来后刷新已听状态（播放器内已写进度）。
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final MediaItem item = _detail ?? widget.item;
    final AudiobookProgress progress = AudiobookProgress.of(context);
    final int continueIndex = progress.continueIndex(item.id);
    final int readCount = progress.readCount(item.id);
    final Set<int> readIndices = progress.readIndices(item.id).toSet();
    final bool hasContinue =
        continueIndex >= 0 && continueIndex < _chapters.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(item.title),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : Column(
                  children: <Widget>[
                    _Header(
                      item: item,
                      source: _source,
                      heroTag: widget.heroTag,
                      chapterCount: _chapters.length,
                      readCount: readCount,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTokens.spaceMd,
                        vertical: AppTokens.spaceSm,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(
                            hasContinue
                                ? '继续收听：第 ${_chapters[continueIndex].number} 章'
                                : '开始收听',
                          ),
                          onPressed: _chapters.isEmpty
                              ? null
                              : () => _openPlayer(
                                    hasContinue ? continueIndex : 0,
                                  ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _chapters.isEmpty
                          ? const _EmptyChaptersView()
                          : AudiobookChapterList(
                              chapters: _chapters,
                              readIndices: readIndices,
                              onChapterTap: _openPlayer,
                            ),
                    ),
                  ],
                ),
    );
  }
}

/// 详情头：封面 + 标题/作者/状态/简介。
class _Header extends StatelessWidget {
  const _Header({
    required this.item,
    required this.source,
    required this.heroTag,
    required this.chapterCount,
    required this.readCount,
  });

  final MediaItem item;
  final PluginConfig? source;
  final String? heroTag;
  final int chapterCount;
  final int readCount;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String? author = item.author;
    final String? status = item.status;
    final String? year = item.year;
    final String? description = item.description;
    final List<String> meta = <String>[
      if (author != null && author.isNotEmpty) author,
      if (status != null && status.isNotEmpty) status,
      if (year != null && year.isNotEmpty) year,
      '$chapterCount 章',
      if (readCount > 0) '已听 $readCount 章',
    ];
    return Padding(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTokens.coverRadius),
            child: SourceImage(
              url: item.coverUrl,
              source: source,
              width: 96,
              height: 128,
              heroTag: heroTag,
              errorWidget: Container(
                width: 96,
                height: 128,
                color: cs.surfaceContainerHighest,
                child: Icon(
                  Icons.headphones_rounded,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppTokens.spaceSm),
                  Text(
                    meta.join(' · '),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (description != null && description.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppTokens.spaceSm),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 章节为空时的空状态。
class _EmptyChaptersView extends StatelessWidget {
  const _EmptyChaptersView();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.headphones_rounded,
            size: 48,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          const Text('暂无章节'),
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            '该源没有返回章节列表',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 加载失败时的错误态（可重试）。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(message),
          const SizedBox(height: AppTokens.spaceMd),
          FilledButton(
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
