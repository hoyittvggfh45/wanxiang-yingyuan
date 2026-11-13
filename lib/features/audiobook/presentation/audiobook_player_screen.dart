/// 听书播放页：复用现有播放器，不另写播放引擎。
///
/// - 播放：[PlayerController]（media_kit/mpv，音视频同一条 `open` 路径，
///   音频直链与视频直链一样打开）；建控制器前先
///   [PlayerController.releaseActive]，与视频播放页同一套防冲突做法；
/// - 后台播放：[AudioPlaybackService]（通知栏/锁屏控件 + 打断处理），
///   每章重新 attach 以刷新通知标题，退出时 detach；
/// - 进度：[AudiobookProgress]（播放位置 + 已听集合），播完自动下一章，
///   达到已看阈值标记已听；
/// - 取流：每章打开时经 [AudiobookService.fetchAudioUrl] 现取 `video`
///   路由直链（不预取整本，避免未听章节的无效请求）。
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
import 'package:wxyy/core/player/audio_playback_service.dart';
import 'package:wxyy/core/player/audiobook_capsule.dart';
import 'package:wxyy/core/player/player_controller.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';
import 'package:wxyy/core/settings/general_settings.dart';
import 'package:wxyy/core/theme/app_tokens.dart';
import 'package:wxyy/core/widgets/source_image.dart';
import 'package:wxyy/features/audiobook/presentation/audiobook_chapter_list.dart';

/// 听书播放页。
class AudiobookPlayerScreen extends StatefulWidget {
  const AudiobookPlayerScreen({
    super.key,
    required this.source,
    required this.item,
    required this.chapters,
    this.initialChapterIndex = 0,
  });

  /// 章节所属的源（取流用）。
  final PluginConfig source;

  /// 作品（标题/封面/进度内容键取自它）。
  final MediaItem item;

  /// 全本章节（过滤后列表，与 [AudiobookChapter.index] 下标一致）。
  final List<Episode> chapters;

  /// 初始章节下标。
  final int initialChapterIndex;

  @override
  State<AudiobookPlayerScreen> createState() => _AudiobookPlayerScreenState();
}

class _AudiobookPlayerScreenState extends State<AudiobookPlayerScreen>
    with WidgetsBindingObserver {
  static const AudiobookService _audiobookService = AudiobookService();

  /// 倍速档位（点倍速按钮循环切换）。
  static const List<double> _speeds = <double>[1.0, 1.25, 1.5, 2.0, 0.75];

  /// 位置写盘节流：两次写盘至少间隔 5 秒（退出/切章时立即写一次）。
  static const Duration _saveThrottle = Duration(seconds: 5);

  PlayerController? _controller;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<AudiobookCapsuleEvent>? _capsuleEventSub;
  late MediaApiService _api;
  late AudiobookProgress _progress;
  HistoryManager? _history;

  int _index = 0;
  double _speed = 1.0;
  bool _loading = true;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// 章节打开代次：快速切章时丢弃过期打开流程的结果。
  int _loadGeneration = 0;

  /// 当前章「续听位置恢复」是否已完成。恢复完成前不写盘，避免刚 open 时
  /// 推送的 position=0 覆盖上次存档（与视频播放页同一坑同一修法）。
  bool _restoreDone = false;

  /// 当前章是否已标记已听（每章只标记一次）。
  bool _markedRead = false;

  DateTime _lastSaveAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _bgToken = -1;
  bool _disposed = false;

  /// 切后台时是否在播（回前台据此决定是否恢复；手动暂停过的不恢复，
  /// 与视频播放页同一做法）。
  bool _playingBeforeBackground = false;

  /// 应用是否已切后台（paused）。胶囊只在切后台且在播时显示。
  bool _backgrounded = false;

  /// 当前播放态（playing 流最新值，驱动胶囊显隐与图标）。
  bool _playing = false;

  /// 悬浮窗权限是否已授予（切后台显示胶囊前复核；无权限诚实降级）。
  bool _capsulePermitted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.chapters.isEmpty
        ? 0
        : widget.initialChapterIndex
            .clamp(0, widget.chapters.length - 1)
            .toInt();
    _api = context.read<MediaApiService>();
    _progress = AudiobookProgress.of(context);
    try {
      _history = context.read<HistoryManager>();
    } on Object {
      _history = null;
    }
    _initController();
  }

  Future<void> _initController() async {
    if (widget.chapters.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    await PlayerController.releaseActive();
    if (_disposed || !mounted) return;
    final PlayerController controller = PlayerController();
    _controller = controller;
    _positionSub = controller.positionStream.listen(_onPosition);
    _completedSub = controller.completedStream.listen(_onCompleted);
    _playingSub = controller.playingStream.listen(_onPlayingChanged);
    _capsuleEventSub =
        AudiobookCapsuleBridge.instance.events.listen(_onCapsuleEvent);
    _openChapter(_index);
  }

  void _onPosition(Duration position) {
    if (_disposed || !mounted) return;
    _position = position;
    if (!_restoreDone) return;
    // 达到已看阈值 → 标记本章已听（阈值取通用设置，默认 90%，与视频一致）。
    if (!_markedRead && _duration > Duration.zero) {
      final int threshold =
          GeneralSettingsStore.instance.settings.watchedThresholdPercent;
      if (position.inMilliseconds * 100 >=
          _duration.inMilliseconds * threshold) {
        _markedRead = true;
        unawaited(_progress.markRead(widget.item.id, _index));
      }
    }
    final DateTime now = DateTime.now();
    if (now.difference(_lastSaveAt) >= _saveThrottle) {
      _lastSaveAt = now;
      _savePosition();
    }
  }

  void _onPlayingChanged(bool playing) {
    if (_disposed) return;
    _playing = playing;
    _syncCapsule();
  }

  /// 原生胶囊按钮点按回传：播放/暂停走控制器；关闭则暂停并收起胶囊；
  /// 点主体时原生已把应用带回前台，这里只作收起兜底。
  void _onCapsuleEvent(AudiobookCapsuleEvent event) {
    if (_disposed || !mounted) return;
    final PlayerController? controller = _controller;
    switch (event) {
      case AudiobookCapsuleEvent.playPause:
        if (controller == null) return;
        unawaited(_playing ? controller.pause() : controller.play());
      case AudiobookCapsuleEvent.close:
        unawaited(controller?.pause());
        unawaited(AudiobookCapsuleBridge.instance.hide());
      case AudiobookCapsuleEvent.tap:
        unawaited(AudiobookCapsuleBridge.instance.hide());
    }
  }

  /// 后台播放：进后台不主动暂停，依赖前台媒体服务保活；切后台且在播时
  /// 显示悬浮胶囊；回到前台收起胶囊，若此前在播却被误暂停则恢复播放。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final PlayerController? controller = _controller;
    if (controller == null) return;
    if (state == AppLifecycleState.paused) {
      _backgrounded = true;
      _playingBeforeBackground = controller.isPlaying;
      _syncCapsule();
    } else if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      unawaited(AudiobookCapsuleBridge.instance.hide());
      if (_playingBeforeBackground && !controller.isPlaying) {
        unawaited(controller.play());
      }
      _playingBeforeBackground = false;
    }
  }

  /// 按当前状态同步胶囊显隐与内容。权限在每次切后台显示前复核一次
  /// （用户可能在设置里刚开/关），无权限时只留通知栏控制。
  void _syncCapsule() {
    if (_disposed || !mounted) return;
    final AudiobookCapsuleBridge bridge = AudiobookCapsuleBridge.instance;
    if (!bridge.supported) return;
    final AudiobookCapsuleInfo info = _capsuleInfo();
    if (!_backgrounded || !_playing) {
      if (bridge.isVisible) unawaited(bridge.hide());
      return;
    }
    unawaited(_showCapsuleIfPermitted(bridge, info));
  }

  Future<void> _showCapsuleIfPermitted(
    AudiobookCapsuleBridge bridge,
    AudiobookCapsuleInfo info,
  ) async {
    _capsulePermitted = await bridge.hasPermission();
    if (_disposed || !mounted) return;
    if (!AudiobookCapsulePolicy.shouldShow(
      backgrounded: _backgrounded,
      playing: _playing,
      permitted: _capsulePermitted,
      supported: bridge.supported,
    )) {
      return;
    }
    if (bridge.isVisible &&
        !AudiobookCapsulePolicy.needsUpdate(bridge.shownInfo, info)) {
      return;
    }
    await bridge.show(info);
  }

  AudiobookCapsuleInfo _capsuleInfo() {
    final Episode chapter = widget.chapters[_index];
    final String title =
        chapter.title.isEmpty ? '第 ${_index + 1} 章' : chapter.title;
    return AudiobookCapsuleInfo(
      title: title,
      artist: widget.item.title,
      artUrl: widget.item.coverUrl,
      playing: _playing,
    );
  }

  /// 悬浮窗权限引导：首次打开章节后，若平台支持但无权限，本次启动内
  /// 提示一次（SnackBar + 去开启按钮），用户拒绝后不再打扰，诚实降级。
  void _maybeNudgeCapsulePermission() {
    final AudiobookCapsuleBridge bridge = AudiobookCapsuleBridge.instance;
    if (!bridge.supported || bridge.permissionNudgeShown) return;
    bridge.markPermissionNudgeShown();
    unawaited(_nudgeCapsulePermissionSlow(bridge));
  }

  Future<void> _nudgeCapsulePermissionSlow(
    AudiobookCapsuleBridge bridge,
  ) async {
    if (await bridge.hasPermission()) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('开启悬浮窗权限后，切后台听书会在桌面显示胶囊'),
        action: SnackBarAction(
          label: '去开启',
          onPressed: () =>
              unawaited(AudiobookCapsuleBridge.instance.requestPermission()),
        ),
      ),
    );
  }

  void _onCompleted(bool completed) {
    if (!completed || _disposed || !mounted) return;
    unawaited(_progress.markRead(widget.item.id, _index));
    _savePosition();
    if (_index + 1 < widget.chapters.length) {
      _openChapter(_index + 1);
    } else {
      // 最后一章播完：无后续内容，胶囊随播放停止消失。
      _syncCapsule();
    }
  }

  Future<void> _openChapter(int index) async {
    final PlayerController? controller = _controller;
    if (controller == null) return;
    final int generation = ++_loadGeneration;
    // 切章前先把上一章的最后位置写盘（下标在 setState 后就变了）。
    if (_restoreDone && _index != index) {
      final int previousIndex = _index;
      final Duration previousPosition = _position;
      unawaited(
        _progress.savePosition(
          widget.item.id,
          previousIndex,
          previousPosition.inMilliseconds,
        ),
      );
    }
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _restoreDone = false;
      _markedRead = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    final Episode chapter = widget.chapters[index];
    VideoResult result;
    try {
      result =
          await _audiobookService.fetchAudioUrl(_api, widget.source, chapter);
    } on Object catch (e) {
      if (generation != _loadGeneration || !mounted) return;
      setState(() {
        _loading = false;
        _error = '取流失败：$e';
      });
      return;
    }
    if (generation != _loadGeneration || !mounted) return;
    try {
      await controller.open(result.url, headers: result.headers);
    } on Object catch (e) {
      if (generation != _loadGeneration || !mounted) return;
      setState(() {
        _loading = false;
        _error = '打开音频失败：$e';
      });
      return;
    }
    if (generation != _loadGeneration || !mounted) return;
    unawaited(controller.setPlaybackSpeed(_speed));
    _attachBackgroundPlayback();
    _recordHistory(chapter);
    setState(() => _loading = false);
    await _restorePosition(controller, generation);
  }

  /// 恢复当前章的续听位置：等到有时长后 seek 到存档点；无存档直接完成。
  Future<void> _restorePosition(
    PlayerController controller,
    int generation,
  ) async {
    final int savedMs = _progress.positionMs(widget.item.id, _index);
    if (savedMs <= 0) {
      _restoreDone = true;
      return;
    }
    try {
      final Duration duration = await controller.durationStream
          .firstWhere((Duration d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10));
      if (generation != _loadGeneration || !mounted) return;
      _duration = duration;
      // 存档点离结尾不足 5 秒时从头播（避免一打开就播完跳章）。
      if (savedMs < duration.inMilliseconds - 5000) {
        await controller.seek(Duration(milliseconds: savedMs));
      }
    } on Object {
      // 恢复失败不致命：从头播，写盘保护照常解除。
    }
    _restoreDone = true;
  }

  void _savePosition() {
    if (!_restoreDone) return;
    unawaited(
      _progress.savePosition(
        widget.item.id,
        _index,
        _position.inMilliseconds,
      ),
    );
  }

  void _recordHistory(Episode chapter) {
    final HistoryManager? history = _history;
    if (history == null) return;
    final String title =
        chapter.title.isEmpty ? '第 ${_index + 1} 章' : chapter.title;
    unawaited(
      history.addHistory(
        widget.item,
        lastChapter: title,
        sourceType: SourceType.audioSource,
      ),
    );
  }

  /// 注册后台播放会话（通知栏/锁屏控件），与视频播放页同一模式。
  ///
  /// 锁屏简化界面：标题=章节名、副标题=书名、封面=作品封面，控件只有
  /// 上一章/播放暂停/下一章 + 进度；封面地址非法时不传 artUri（通知无图，
  /// 不编假图）。
  void _attachBackgroundPlayback() {
    final PlayerController? controller = _controller;
    if (controller == null) return;
    final Episode chapter = widget.chapters[_index];
    final String title =
        chapter.title.isEmpty ? '第 ${_index + 1} 章' : chapter.title;
    final String? coverUrl = widget.item.coverUrl;
    final Uri? artUri = coverUrl != null && coverUrl.isNotEmpty
        ? Uri.tryParse(coverUrl)
        : null;
    _bgToken = AudioPlaybackService.instance.attach(
      AudioPlaybackSession(
        id: '${widget.source.id}::${chapter.id}',
        title: title,
        artist: widget.item.title,
        artUri: artUri != null && artUri.hasScheme ? artUri : null,
        positionStream: controller.positionStream,
        durationStream: controller.durationStream,
        playingStream: controller.playingStream,
        onPlay: () => controller.play(),
        onPause: () => controller.pause(),
        onSeek: (Duration p) => controller.seek(p),
        onNext: _index + 1 < widget.chapters.length
            ? () async => _openChapter(_index + 1)
            : null,
        onPrev: _index > 0 ? () async => _openChapter(_index - 1) : null,
      ),
    );
    // 切章时胶囊内容（章节名）同步刷新；首次打开时提示一次悬浮窗权限。
    _syncCapsule();
    _maybeNudgeCapsulePermission();
  }

  void _cycleSpeed() {
    final int next = (_speeds.indexOf(_speed) + 1) % _speeds.length;
    setState(() => _speed = _speeds[next]);
    unawaited(_controller?.setPlaybackSpeed(_speed));
  }

  void _showChapterSheet() {
    final List<AudiobookChapter> chapters = audiobookChaptersFromEpisodes(
      widget.chapters,
    );
    final Set<int> read = _progress.readIndices(widget.item.id).toSet();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.6,
        child: AudiobookChapterList(
          chapters: chapters,
          readIndices: read,
          currentIndex: _index,
          onChapterTap: (int i) {
            Navigator.of(ctx).pop();
            if (i != _index) _openChapter(i);
          },
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final int totalSeconds = d.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _savePosition();
    _positionSub?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _capsuleEventSub?.cancel();
    unawaited(AudiobookCapsuleBridge.instance.hide());
    if (_bgToken >= 0) {
      AudioPlaybackService.instance.detach(_bgToken);
    }
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.item.title)),
        body: const Center(child: Text('暂无章节')),
      );
    }
    final PlayerController? controller = _controller;
    final Episode chapter = widget.chapters[_index];
    final String chapterTitle =
        chapter.title.isEmpty ? '第 ${_index + 1} 章' : chapter.title;
    final ColorScheme cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.title),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.list_rounded),
            tooltip: '章节列表',
            onPressed: _showChapterSheet,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          children: <Widget>[
            const SizedBox(height: AppTokens.spaceLg),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.coverRadius),
              child: SourceImage(
                url: widget.item.coverUrl,
                source: widget.source,
                width: 200,
                height: 200,
                fit: BoxFit.cover,
                errorWidget: Container(
                  width: 200,
                  height: 200,
                  color: cs.surfaceContainerHighest,
                  child: Icon(
                    Icons.headphones_rounded,
                    size: 64,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            Text(
              chapterTitle,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '第 ${_index + 1} 章 / 共 ${widget.chapters.length} 章',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppTokens.spaceMd),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              _PlayerError(
                  message: _error!, onRetry: () => _openChapter(_index))
            else if (controller != null)
              _ProgressSlider(
                controller: controller,
                formatDuration: _formatDuration,
                onDuration: (Duration d) => _duration = d,
              ),
            const Spacer(),
            _Controls(
              controller: controller,
              enabled: !_loading && _error == null,
              speed: _speed,
              hasPrev: _index > 0,
              hasNext: _index + 1 < widget.chapters.length,
              onPrev: () => _openChapter(_index - 1),
              onNext: () => _openChapter(_index + 1),
              onSpeed: _cycleSpeed,
            ),
            const SizedBox(height: AppTokens.spaceLg),
          ],
        ),
      ),
    );
  }
}

/// 播放进度条：位置/时长取自控制器流，拖动即 seek。
class _ProgressSlider extends StatelessWidget {
  const _ProgressSlider({
    required this.controller,
    required this.formatDuration,
    required this.onDuration,
  });

  final PlayerController controller;
  final String Function(Duration) formatDuration;
  final void Function(Duration) onDuration;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: controller.durationStream,
      builder: (BuildContext context, AsyncSnapshot<Duration> durationSnap) {
        final Duration duration = durationSnap.data ?? Duration.zero;
        onDuration(duration);
        return StreamBuilder<Duration>(
          stream: controller.positionStream,
          builder:
              (BuildContext context, AsyncSnapshot<Duration> positionSnap) {
            final Duration position = positionSnap.data ?? Duration.zero;
            final double max = duration.inMilliseconds.toDouble();
            final double value =
                position.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
            return Column(
              children: <Widget>[
                Slider(
                  value: max > 0 ? value : 0.0,
                  max: max > 0 ? max : 1.0,
                  onChanged: max > 0
                      ? (double v) => unawaited(
                            controller.seek(
                              Duration(milliseconds: v.round()),
                            ),
                          )
                      : null,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(formatDuration(position)),
                    Text(formatDuration(duration)),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 播放控制行：上一章 / 播放暂停 / 下一章 / 倍速。
class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.enabled,
    required this.speed,
    required this.hasPrev,
    required this.hasNext,
    required this.onPrev,
    required this.onNext,
    required this.onSpeed,
  });

  final PlayerController? controller;
  final bool enabled;
  final double speed;
  final bool hasPrev;
  final bool hasNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onSpeed;

  @override
  Widget build(BuildContext context) {
    final PlayerController? c = controller;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        TextButton(
          onPressed: enabled ? onSpeed : null,
          child: Text('${speed}x'),
        ),
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 36,
          tooltip: '上一章',
          onPressed: enabled && hasPrev ? onPrev : null,
        ),
        const SizedBox(width: AppTokens.spaceSm),
        StreamBuilder<bool>(
          stream: c?.playingStream,
          builder: (BuildContext context, AsyncSnapshot<bool> snap) {
            final bool playing = snap.data ?? false;
            return FilledButton(
              onPressed: enabled && c != null
                  ? () => unawaited(playing ? c.pause() : c.play())
                  : null,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(AppTokens.spaceMd),
              ),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 36,
              ),
            );
          },
        ),
        const SizedBox(width: AppTokens.spaceSm),
        IconButton(
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 36,
          tooltip: '下一章',
          onPressed: enabled && hasNext ? onNext : null,
        ),
      ],
    );
  }
}

/// 取流/打开失败时的错误态（可重试本章）。
class _PlayerError extends StatelessWidget {
  const _PlayerError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: AppTokens.spaceMd),
        FilledButton(
          onPressed: onRetry,
          child: const Text('重试'),
        ),
      ],
    );
  }
}
