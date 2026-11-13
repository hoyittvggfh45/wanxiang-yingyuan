/// 详情页内嵌播放器：取代详情页顶部的海报位，点播放直接在详情页内播。
///
/// 模式与 RSS 内嵌播放器一致：16:9 内嵌、点击才创建播放器、全屏复用同一
/// 个 [PlayerController] / [VideoController]（进度不丢），控制层复用
/// [RssVideoControls]（播放/暂停、进度、倍速、音量、全屏）。详情版另加：
/// 上一集 / 下一集、选集面板、线路切换、播完自动下一集。
///
/// 播放地址先查预加载缓存（[PreloadQueue]，开关默认开），命中直接播，
/// 未命中经 [MediaApiService.fetchVideoUrl] 现取当前集地址（含蜘蛛源的
/// playerContent），解析失败或引擎未接通时显示诚实错误，不静默失败、
/// 不假装可播。当前集确定后驱动预加载队列重算（往后 5 集 + 后续影视首集）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/media/media_kit_network.dart';
import '../../../core/models/episode.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/player/player_controller.dart';
import '../../../core/player/playback_shunt.dart';
import '../../../core/player/player_runtime.dart';
import '../../../core/player/preload_queue.dart';
import '../../../core/scraper/media_api_service.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/settings/player_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_log.dart';
import '../../player/presentation/playback_shunt_views.dart';
import '../../rss/presentation/rss_inline_video_player.dart';

/// 详情页内嵌播放器（影视/动漫源详情页顶部）。
class DetailInlinePlayer extends StatefulWidget {
  /// 当前源配置（取流解析用）。
  final PluginConfig source;

  /// 全部剧集（选集/上下集用）。
  final List<Episode> episodes;

  /// 当前剧集在 [episodes] 中的索引。
  final int currentIndex;

  /// 播放令牌：父组件每次要求播放（点选某集、继续观看）时递增，
  /// 本组件检测到变化即解析并播放 [currentIndex] 对应的剧集。
  final int playToken;

  /// 封面地址（未播放时占位图）。
  final String? coverUrl;

  /// 作品标题（全屏顶栏显示）。
  final String title;

  /// 切集回调：上一集/下一集/选集/播完自动下一集时通知父组件，
  /// 由父组件更新 [currentIndex] 并递增 [playToken]。
  final ValueChanged<int> onEpisodeChange;

  /// 后续影视（列表里当前作品往后的 1–3 部）：预加载其首集地址。
  /// 为空时只预加载本作品往后 5 集。
  final List<MediaItem> upcomingItems;

  /// 当前作品条目（可选）：播首集时可命中“后续影视首集”预加载缓存
  /// （上一个详情页预加载的首集地址存在共享缓存里）。
  final MediaItem? contentItem;

  const DetailInlinePlayer({
    super.key,
    required this.source,
    required this.episodes,
    required this.currentIndex,
    required this.playToken,
    required this.onEpisodeChange,
    this.coverUrl,
    required this.title,
    this.upcomingItems = const <MediaItem>[],
    this.contentItem,
  });

  @override
  State<DetailInlinePlayer> createState() => _DetailInlinePlayerState();
}

class _DetailInlinePlayerState extends State<DetailInlinePlayer> {
  static const Duration _loadTimeout = Duration(seconds: 20);

  PlayerController? _pc;
  VideoController? _vc;
  bool _started = false;
  bool _resolving = false;
  bool _failed = false;
  String? _failureMessage;
  bool _retried = false;
  int _appliedToken = -1;
  int _appliedIndex = -1;
  List<VideoLine> _lines = const <VideoLine>[];
  int _lineIndex = 0;
  Timer? _loadTimer;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _completedSub;

  /// 预加载队列：后台只解析地址并缓存（见 [PreloadQueue]）。
  PreloadQueue? _preloadQueue;

  /// 协议分流决策：novel/pics 时显示分流视图、不打开媒体；
  /// audio 时照常打开媒体、只把视频画面换成音频封面。
  PlaybackDecision? _shunt;

  /// 当前是否为音频模式（分流判为音频）。
  bool get _isAudioMode => _shunt?.kind == PlaybackKind.audio;

  /// 详情条目带的 `vod_tag`（分流双认信号）。
  String? get _vodTag {
    final Object? tag = widget.contentItem?.extra?['vod_tag'];
    return tag?.toString();
  }

  @override
  void initState() {
    super.initState();
    PlayerRuntime.ensureInitialized();
  }

  @override
  void didUpdateWidget(DetailInlinePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playToken != _appliedToken ||
        widget.currentIndex != _appliedIndex) {
      unawaited(_playEpisode(widget.currentIndex));
    } else if (_preloadQueue != null &&
        widget.episodes.length != oldWidget.episodes.length) {
      // 剧集列表渐进增长（集数变多）时刷新窗口，不重新播当前集。
      _preloadQueue!.update(
        episodes: widget.episodes,
        currentIndex: widget.currentIndex,
        upcomingItems: widget.upcomingItems,
      );
    }
  }

  /// 惰性创建预加载队列：解析回调复用详情页现有的取流设施
  /// （[MediaApiService.fetchVideoUrl] / [MediaApiService.fetchEpisodes]）。
  ///
  /// 源仓库读取失败时首集解析回调恒返回 null（只影响后续影视预加载，
  /// 不影响本作品预加载与正常播放）。
  PreloadQueue _ensurePreloadQueue(MediaApiService apiService) {
    final PreloadQueue? existing = _preloadQueue;
    if (existing != null) return existing;
    SourceRepository? repo;
    try {
      repo = context.read<SourceRepository>();
    } on Object {
      repo = null;
    }
    final SourceRepository? sourceRepo = repo;
    final PreloadQueue queue = PreloadQueue(
      resolveEpisode: (Episode ep) =>
          apiService.fetchVideoUrl(widget.source, ep.url),
      resolveFirstEpisode: (MediaItem item) async {
        final SourceRepository? r = sourceRepo;
        final String? sid = item.sourceId;
        if (r == null || sid == null || sid.isEmpty) return null;
        final PluginConfig? cfg = r.getById(sid);
        if (cfg == null) return null;
        final List<Episode> eps = await apiService.fetchEpisodes(
          cfg,
          item.id,
          title: item.title,
          detailUrl: item.detailUrl,
        );
        if (eps.isEmpty) return null;
        return apiService.fetchVideoUrl(cfg, eps.first.url);
      },
      keyOfEpisode: (Episode ep) =>
          PreloadQueue.episodeKey(widget.source.id, ep),
    );
    _preloadQueue = queue;
    return queue;
  }

  /// 每次切集重读预加载开关：设置页改了开关后切集即生效，不必重进详情页。
  /// 读取失败按默认开启处理（与 [PlayerSettings] 默认值一致）。
  Future<void> _refreshPreloadEnabled(PreloadQueue queue) async {
    bool enabled = true;
    try {
      enabled = (await PlayerSettingsStore().load()).preloadEnabled;
    } on Object {
      enabled = true;
    }
    if (!mounted) return;
    queue.setEnabled(enabled);
  }

  Episode? get _currentEpisode {
    if (widget.currentIndex < 0 ||
        widget.currentIndex >= widget.episodes.length) {
      return null;
    }
    return widget.episodes[widget.currentIndex];
  }

  Future<void> _ensurePlayer() async {
    if (_started) return;
    final PlayerController pc = PlayerController();
    final VideoController vc = VideoController(pc.player);
    _pc = pc;
    _vc = vc;
    _started = true;
    // 全屏退出后恢复的方向按「锁定方向」设置注入（默认竖屏），
    // 与播放器页锁定方向的注入口径一致。
    unawaited(_applyBaseOrientations(pc));
    final Player player = pc.player;
    _durSub = player.stream.duration.listen((Duration d) {
      if (!mounted) return;
      if (d > Duration.zero) {
        _loadTimer?.cancel();
        _loadTimer = null;
        if (_failed) setState(() => _failed = false);
      }
    });
    _errorSub = player.stream.error.listen((String message) {
      AppLog.instance.w('详情内播内核报错: $message');
      if (!mounted) return;
      _loadTimer?.cancel();
      _loadTimer = null;
      if (!_retried) {
        _retried = true;
        unawaited(_openCurrentLine());
        return;
      }
      setState(() {
        _failed = true;
        _failureMessage = message.isEmpty ? '播放器内核报错' : message;
      });
    });
    _completedSub = player.stream.completed.listen((bool c) {
      if (!c || !mounted) return;
      final int next = widget.currentIndex + 1;
      if (next < widget.episodes.length) {
        widget.onEpisodeChange(next);
      }
    });
    if (mounted) setState(() {});
  }

  Future<void> _playEpisode(int index) async {
    final Episode? ep = index >= 0 && index < widget.episodes.length
        ? widget.episodes[index]
        : null;
    if (ep == null) return;
    // 取流服务在第一个 await 之前取出，避免跨异步间隙使用 context。
    final MediaApiService apiService = context.read<MediaApiService>();
    final PreloadQueue preloadQueue = _ensurePreloadQueue(apiService);
    _appliedToken = widget.playToken;
    _appliedIndex = index;
    // 分流（解析前）：剧集地址 / id 自带协议、或详情 vod_tag 指明时，
    // 直接进分流视图，不创建播放器、不取流。
    final PlaybackDecision preDecision = classifyPlayback(
      url: ep.url,
      episodeId: ep.id,
      vodTag: _vodTag,
      fallbackTitle: widget.title,
    );
    if (preDecision.kind == PlaybackKind.novel ||
        preDecision.kind == PlaybackKind.pics) {
      if (!mounted) return;
      setState(() {
        _started = true;
        _resolving = false;
        _failed = false;
        _failureMessage = null;
        _lines = const <VideoLine>[];
        _shunt = preDecision;
      });
      return;
    }
    await _ensurePlayer();
    if (!mounted) return;
    await _refreshPreloadEnabled(preloadQueue);
    if (!mounted) return;
    setState(() {
      _resolving = true;
      _failed = false;
      _failureMessage = null;
      _retried = false;
      _lineIndex = 0;
      _shunt = preDecision.shunted ? preDecision : null;
    });
    try {
      // 先查预加载缓存，命中直接播；未命中走正常取流（失败显示真实错误）。
      final MediaItem? content = widget.contentItem;
      final VideoResult result = preloadQueue.lookupEpisode(ep) ??
          (index == 0 && content != null
              ? preloadQueue.lookupFirstEpisode(content)
              : null) ??
          await apiService.fetchVideoUrl(widget.source, ep.url);
      if (!mounted) return;
      // 分流（解析后）：已解析直链再判一次，命中小说/图片则不打开。
      final PlaybackDecision resolvedDecision = classifyPlayback(
        url: result.url,
        episodeId: ep.id,
        vodTag: _vodTag,
        headers: result.headers,
        fallbackTitle: widget.title,
      );
      if (resolvedDecision.kind == PlaybackKind.novel ||
          resolvedDecision.kind == PlaybackKind.pics) {
        setState(() {
          _resolving = false;
          _failed = false;
          _lines = const <VideoLine>[];
          _shunt = resolvedDecision;
        });
        return;
      }
      _shunt = resolvedDecision.shunted ? resolvedDecision : null;
      _lines = result.lines.isNotEmpty
          ? result.lines
          : <VideoLine>[
              VideoLine(name: '', url: result.url, headers: result.headers),
            ];
      if (_lines.isEmpty || _lines.first.url.isEmpty) {
        throw StateError('解析到的播放地址为空');
      }
      // 当前集确定后驱动队列重算：窗口滑动补齐 + 后续影视首集。
      preloadQueue.update(
        episodes: widget.episodes,
        currentIndex: index,
        upcomingItems: widget.upcomingItems,
      );
      await _openCurrentLine();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _failed = true;
        _failureMessage = e.toString();
      });
    }
  }

  Future<void> _openCurrentLine() async {
    final PlayerController? pc = _pc;
    if (pc == null || !mounted || _lines.isEmpty) return;
    setState(() {
      _failed = false;
      _failureMessage = null;
    });
    final VideoLine line = _lines[_lineIndex.clamp(0, _lines.length - 1)];
    // 分流（开播前最后一道）：行地址命中小说/图片时不送解码。
    final PlaybackDecision lineDecision = classifyPlayback(
      url: line.url,
      headers: line.headers,
      fallbackTitle: widget.title,
    );
    if (lineDecision.kind == PlaybackKind.novel ||
        lineDecision.kind == PlaybackKind.pics) {
      setState(() {
        _resolving = false;
        _shunt = lineDecision;
      });
      return;
    }
    _shunt = lineDecision.shunted ? lineDecision : null;
    unawaited(applyAppProxyToPlayer(pc.player));
    unawaited(_setNetworkTimeout());
    await pc.open(line.url, headers: line.headers);
    await pc.play();
    if (!mounted) return;
    setState(() => _resolving = false);
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, () {
      if (!mounted) return;
      if (pc.player.state.duration > Duration.zero || pc.player.state.playing) {
        return;
      }
      setState(() {
        _failed = true;
        _failureMessage = '加载超时（20 秒无时长未起播），请检查网络后重试';
      });
    });
  }

  Future<void> _setNetworkTimeout() async {
    final Object? platform = _pc?.player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('network-timeout', '60');
    } on Object {
      // 注入失败不阻塞播放。
    }
  }

  Future<void> _switchLine(int index) async {
    if (index == _lineIndex || index < 0 || index >= _lines.length) return;
    setState(() => _lineIndex = index);
    await _openCurrentLine();
  }

  /// 全屏退出后恢复的方向：按「锁定方向」设置注入给控制器（默认竖屏）。
  ///
  /// 只影响全屏退出时的恢复方向，不锁定详情页本身的方向（详情页浏览
  /// 时跟随系统/传感器）。映射与播放器页一致：竖屏→portraitUp、
  /// 横屏→双横屏、自动→空（跟随传感器）；平板/桌面不注入（窗口自由调整）。
  Future<void> _applyBaseOrientations(PlayerController pc) async {
    try {
      final PlayerSettings settings = await PlayerSettingsStore().load();
      if (!mounted) return;
      final bool isPhone =
          MediaQuery.of(context).size.shortestSide < 600;
      final List<DeviceOrientation> orients;
      if (!isPhone) {
        orients = const <DeviceOrientation>[];
      } else {
        switch (settings.lockOrientation) {
          case PlayerLockOrientation.portrait:
            orients = const <DeviceOrientation>[
              DeviceOrientation.portraitUp,
            ];
          case PlayerLockOrientation.landscape:
            orients = const <DeviceOrientation>[
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ];
          case PlayerLockOrientation.auto:
            orients = const <DeviceOrientation>[];
        }
      }
      pc.setBaseOrientations(orients);
    } on Object {
      // 设置读取失败不影响播放：控制器保持默认自动跟随。
    }
  }

  Future<void> _openFullscreen() async {
    // 音频模式无画面可全屏；分流视图下全屏按钮不可达，同样拦截。
    if (_isAudioMode || _shunt != null) return;
    final PlayerController? pc = _pc;
    final VideoController? vc = _vc;
    if (!mounted || pc == null || vc == null) return;
    // 进全屏前刷新一次恢复方向，取设置页最新值（默认竖屏）。
    await _applyBaseOrientations(pc);
    if (!mounted) return;
    await pc.toggleFullscreen();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailVideoFullscreen(
          controller: pc,
          videoController: vc,
          title: widget.title,
          episodeTitle: _currentEpisode?.title ?? '',
          hasPrev: widget.currentIndex > 0,
          hasNext: widget.currentIndex + 1 < widget.episodes.length,
          onPrev: () => widget.onEpisodeChange(widget.currentIndex - 1),
          onNext: () => widget.onEpisodeChange(widget.currentIndex + 1),
          onPickEpisode: () => _showEpisodePicker(context),
        ),
      ),
    );
    await pc.toggleFullscreen();
  }

  Future<void> _showEpisodePicker(BuildContext context) async {
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (BuildContext ctx, ScrollController scrollController) =>
            _EpisodePickerSheet(
              episodes: widget.episodes,
              currentIndex: widget.currentIndex,
              scrollController: scrollController,
            ),
      ),
    );
    if (picked != null && picked != widget.currentIndex) {
      widget.onEpisodeChange(picked);
    }
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _errorSub?.cancel();
    _durSub?.cancel();
    _completedSub?.cancel();
    _preloadQueue?.dispose();
    _preloadQueue = null;
    _pc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Episode? ep = _currentEpisode;
    final PlaybackDecision? shunt = _shunt;
    final Widget mediaChild;
    if (shunt != null &&
        (shunt.kind == PlaybackKind.novel ||
            shunt.kind == PlaybackKind.pics)) {
      // 分流视图：小说/图片不送解码；拦截态显示诚实错误与重试。
      if (shunt.blocked) {
        mediaChild = ShuntBlockedView(
          reason: shunt.blockedReason!,
          onRetry: () => unawaited(_playEpisode(widget.currentIndex)),
        );
      } else if (shunt.kind == PlaybackKind.novel) {
        mediaChild =
            ShuntNovelView(content: shunt.content!, title: widget.title);
      } else {
        mediaChild =
            ShuntPicsView(content: shunt.content!, title: widget.title);
      }
    } else if (!_started) {
      mediaChild = _IdleCover(
        coverUrl: widget.coverUrl,
        episodeTitle: ep?.title,
        onPlay: () => unawaited(_playEpisode(widget.currentIndex)),
      );
    } else {
      mediaChild = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 音频模式：视频画面换成封面区，控制层共用同一套。
          if (_isAudioMode)
            ShuntAudioCover(title: widget.title, coverUrl: widget.coverUrl)
          else
            Video(
              controller: _vc!,
              controls: NoVideoControls,
              fit: BoxFit.contain,
            ),
          if (_resolving)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          if (_failed)
            _InlineFailure(
              message: _failureMessage,
              onRetry: () => unawaited(_playEpisode(widget.currentIndex)),
            )
          else if (!_resolving)
            RssVideoControls(
              controller: _pc!,
              videoController: _vc!,
              showFullscreenButton: !_isAudioMode,
              onToggleFullscreen: () => unawaited(_openFullscreen()),
            ),
        ],
      );
    }
    // 小说正文需要纵向空间：分流小说时盒子加高；图片/视频保持 16:9。
    final Widget mediaBox = shunt?.kind == PlaybackKind.novel
        ? SizedBox(
            height: 420,
            child: ColoredBox(color: Colors.black, child: mediaChild),
          )
        : AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(color: Colors.black, child: mediaChild),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        mediaBox,
        // 选集条：上一集 / 当前集 + 选集 / 下一集 / 线路。
        Container(
          color: Colors.black,
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceSm,
            vertical: 4,
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                icon: const Icon(
                  Icons.skip_previous_rounded,
                  color: Colors.white,
                ),
                tooltip: '上一集',
                onPressed: widget.currentIndex > 0
                    ? () => widget.onEpisodeChange(widget.currentIndex - 1)
                    : null,
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => _showEpisodePicker(context),
                  child: Text(
                    ep?.title ?? '选集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              if (_lines.length > 1)
                TextButton(
                  onPressed: () => _showLinePicker(context),
                  child: Text(
                    _lines[_lineIndex].name.isEmpty
                        ? '线路 ${_lineIndex + 1}'
                        : _lines[_lineIndex].name,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                tooltip: '下一集',
                onPressed: widget.currentIndex + 1 < widget.episodes.length
                    ? () => widget.onEpisodeChange(widget.currentIndex + 1)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showLinePicker(BuildContext context) async {
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('选择线路'),
        children: <Widget>[
          for (int i = 0; i < _lines.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(i),
              child: Text(
                _lines[i].name.isEmpty ? '线路 ${i + 1}' : _lines[i].name,
              ),
            ),
        ],
      ),
    );
    if (picked != null) unawaited(_switchLine(picked));
  }
}

/// 全屏播放页：复用同一 [VideoController]（进度不丢），不创建新 Player。
class DetailVideoFullscreen extends StatelessWidget {
  final PlayerController controller;
  final VideoController videoController;
  final String title;
  final String episodeTitle;
  final bool hasPrev;
  final bool hasNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPickEpisode;

  const DetailVideoFullscreen({
    super.key,
    required this.controller,
    required this.videoController,
    required this.title,
    required this.episodeTitle,
    required this.hasPrev,
    required this.hasNext,
    required this.onPrev,
    required this.onNext,
    required this.onPickEpisode,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Video(
              controller: videoController,
              controls: NoVideoControls,
              fit: BoxFit.contain,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Colors.black54, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        episodeTitle.isEmpty ? title : '$title · $episodeTitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_previous_rounded,
                        color: Colors.white,
                      ),
                      tooltip: '上一集',
                      onPressed: hasPrev ? onPrev : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.list_rounded, color: Colors.white),
                      tooltip: '选集',
                      onPressed: onPickEpisode,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: Colors.white,
                      ),
                      tooltip: '下一集',
                      onPressed: hasNext ? onNext : null,
                    ),
                  ],
                ),
              ),
            ),
            RssVideoControls(
              controller: controller,
              videoController: videoController,
              onToggleFullscreen: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未播放时的占位：封面 + 大播放按钮 + 当前集名。
class _IdleCover extends StatelessWidget {
  final String? coverUrl;
  final String? episodeTitle;
  final VoidCallback onPlay;

  const _IdleCover({this.coverUrl, this.episodeTitle, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final String? url = coverUrl;
    return GestureDetector(
      onTap: onPlay,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (url != null && url.isNotEmpty)
            Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          Container(color: Colors.black45),
          Center(
            child: IconButton(
              iconSize: 64,
              icon: const Icon(
                Icons.play_circle_fill_rounded,
                color: Colors.white,
              ),
              onPressed: onPlay,
            ),
          ),
          if (episodeTitle != null && episodeTitle!.isNotEmpty)
            Positioned(
              left: AppTokens.spaceMd,
              right: AppTokens.spaceMd,
              bottom: AppTokens.spaceSm,
              child: Text(
                episodeTitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

/// 内播解析/加载失败态：显示真实错误 + 重试。
class _InlineFailure extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;

  const _InlineFailure({this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.white70,
              size: 32,
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              message ?? '播放失败',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, color: Colors.white),
              label: const Text('重试', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选集面板：网格列出全部剧集，点选返回索引。
class _EpisodePickerSheet extends StatelessWidget {
  final List<Episode> episodes;
  final int currentIndex;
  final ScrollController scrollController;

  const _EpisodePickerSheet({
    required this.episodes,
    required this.currentIndex,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Text(
            '选集（共 ${episodes.length} 集）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: GridView.builder(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: AppTokens.spaceSm,
              crossAxisSpacing: AppTokens.spaceSm,
              childAspectRatio: 2.2,
            ),
            itemCount: episodes.length,
            itemBuilder: (BuildContext ctx, int i) {
              final bool current = i == currentIndex;
              return FilledButton.tonal(
                onPressed: () => Navigator.of(ctx).pop(i),
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: current
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                child: Text(
                  episodes[i].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: current ? Theme.of(ctx).colorScheme.onPrimary : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
