/// 直播房间页：直播列表点频道后进这里（列表 → 房间 → 全屏播放页）。
///
/// 结构对照魔蚁直播：房间页顶部是 16:9 内嵌播放器（与全屏共用同一个
/// [PlayerController] / [VideoController]，换台不重建引擎），下方是
/// 分组栏 + 频道列表，点频道就地换台；点全屏键才进横屏全屏页，退出回竖屏。
/// 控制层复用 [RssVideoControls]（播放/暂停、进度、倍速、音量、全屏），
/// 与详情页内嵌播放器同一套，不另起播放器实现。
///
/// 方向：房间页本身不锁方向（默认竖屏浏览）；横屏只发生在用户点全屏键后，
/// 由 [PlayerController.toggleFullscreen] 锁定横屏 + 沉浸式，退出时按
/// 「锁定方向」设置恢复（默认竖屏）。不走 [VideoPlayerScreen]，也就不会
/// 触发它那个“起播自动全屏”的逻辑。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/live/live_models.dart';
import '../../../core/live/live_playlist.dart';
import '../../../core/media/media_kit_network.dart';
import '../../../core/player/player_controller.dart';
import '../../../core/player/player_runtime.dart';
import '../../../core/settings/player_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_log.dart';
import '../../rss/presentation/rss_inline_video_player.dart';

/// 直播房间页：播 [initialChannel]，频道表为 [result] 的全部频道。
class LiveRoomScreen extends StatefulWidget {
  /// 当前生效的清单解析结果（分组 + 频道全表）。
  final LiveParseResult result;

  /// 进房间时要播的频道（列表页点中的那条）。
  final LiveChannel initialChannel;

  const LiveRoomScreen({
    super.key,
    required this.result,
    required this.initialChannel,
  });

  @override
  State<LiveRoomScreen> createState() => _LiveRoomScreenState();
}

class _LiveRoomScreenState extends State<LiveRoomScreen> {
  /// 起播后迟迟没画面的判定时限（与详情内播一致的 20 秒口径）。
  static const Duration _loadTimeout = Duration(seconds: 20);

  late final LivePlaylist _playlist;
  late final PlayerController _pc;
  late final VideoController _vc;

  /// 列表区当前选中的分组；空字符串表示“全部”。只过滤列表，不打断播放。
  String _selectedGroup = '';
  bool _opening = false;
  bool _failed = false;
  String? _failureMessage;

  Timer? _loadTimer;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;

  LiveChannel? get _channel => _playlist.channel;

  @override
  void initState() {
    super.initState();
    PlayerRuntime.ensureInitialized();
    final List<LiveChannel> flat = flattenLiveGroups(widget.result.groups);
    _playlist = LivePlaylist(channels: flat);
    final int at = _playlist.indexOfKey(widget.initialChannel.key);
    _playlist.play(at >= 0 ? at : 0);
    _selectedGroup = _channel?.group ?? '';
    _pc = PlayerController();
    _vc = VideoController(_pc.player);
    unawaited(_applyBaseOrientations());
    final Player player = _pc.player;
    _durSub = player.stream.duration.listen((Duration d) {
      if (!mounted) return;
      if (d > Duration.zero) {
        _loadTimer?.cancel();
        _loadTimer = null;
        if (_failed) setState(() => _failed = false);
      }
    });
    _playingSub = player.stream.playing.listen((bool playing) {
      if (!mounted || !playing) return;
      _loadTimer?.cancel();
      _loadTimer = null;
      if (_failed) setState(() => _failed = false);
    });
    _errorSub = player.stream.error.listen((String message) {
      AppLog.instance.w('直播房间内核报错: $message');
      if (!mounted || _failed) return;
      // 还有备用线路时自动换下一条线重播（魔蚁重连换线口径）；
      // 线路试完才落到失败态，让用户手动重试 / 换台。
      if (_playlist.hasUntriedRoute) {
        _playlist.playRoute(_playlist.route + 1);
        unawaited(_openCurrent());
        return;
      }
      _loadTimer?.cancel();
      _loadTimer = null;
      setState(() {
        _failed = true;
        _failureMessage = message.isEmpty ? '直播中断' : message;
      });
    });
    unawaited(_openCurrent());
  }

  /// 全屏退出后恢复的方向：按「锁定方向」设置注入（默认竖屏）。
  /// 只影响全屏退出时的恢复方向，不锁定房间页本身。
  Future<void> _applyBaseOrientations() async {
    try {
      final PlayerSettings settings = await PlayerSettingsStore().load();
      if (!mounted) return;
      final bool isPhone = MediaQuery.of(context).size.shortestSide < 600;
      final List<DeviceOrientation> orients;
      if (!isPhone) {
        orients = const <DeviceOrientation>[];
      } else {
        switch (settings.lockOrientation) {
          case PlayerLockOrientation.portrait:
            orients = const <DeviceOrientation>[DeviceOrientation.portraitUp];
          case PlayerLockOrientation.landscape:
            orients = const <DeviceOrientation>[
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ];
          case PlayerLockOrientation.auto:
            orients = const <DeviceOrientation>[];
        }
      }
      _pc.setBaseOrientations(orients);
    } on Object {
      // 设置读取失败不影响播放：控制器保持默认自动跟随。
    }
  }

  Future<void> _openCurrent() async {
    final String url = _playlist.url;
    if (url.isEmpty) {
      setState(() {
        _opening = false;
        _failed = true;
        _failureMessage = '该频道没有可用的播放地址';
      });
      return;
    }
    setState(() {
      _opening = true;
      _failed = false;
      _failureMessage = null;
    });
    unawaited(applyAppProxyToPlayer(_pc.player));
    try {
      await _pc.open(url);
      await _pc.play();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _failed = true;
        _failureMessage = e.toString();
      });
      return;
    }
    if (!mounted) return;
    setState(() => _opening = false);
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, () {
      if (!mounted) return;
      if (_pc.player.state.duration > Duration.zero ||
          _pc.player.state.playing) {
        return;
      }
      setState(() {
        _failed = true;
        _failureMessage = '加载超时（20 秒未起播），请检查网络后重试';
      });
    });
  }

  void _playIndex(int index) {
    final LiveChannel target = _playlist.channels[index];
    if (!target.playable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该频道没有可用的播放地址')));
      return;
    }
    _loadTimer?.cancel();
    _loadTimer = null;
    setState(() => _playlist.play(index));
    unawaited(_openCurrent());
  }

  void _switchBy(int delta) {
    if (_playlist.length < 2) return;
    _loadTimer?.cancel();
    _loadTimer = null;
    setState(() => _playlist.switchBy(delta));
    unawaited(_openCurrent());
  }

  Future<void> _switchRoute(int route) async {
    if (route == _playlist.route) return;
    _loadTimer?.cancel();
    _loadTimer = null;
    setState(() => _playlist.playRoute(route));
    await _openCurrent();
  }

  Future<void> _showRoutePicker(BuildContext context) async {
    final LiveChannel? channel = _channel;
    if (channel == null || channel.urls.length < 2) return;
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('选择线路'),
        children: <Widget>[
          for (int i = 0; i < channel.urls.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(i),
              child: Text(
                '线路 ${i + 1}${i == _playlist.route ? '（当前）' : ''}',
              ),
            ),
        ],
      ),
    );
    if (picked != null) unawaited(_switchRoute(picked));
  }

  Future<void> _showChannelPicker(BuildContext context) async {
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (BuildContext ctx, ScrollController scrollController) =>
            _ChannelPickerSheet(
              channels: _playlist.channels,
              currentIndex: _playlist.index,
              scrollController: scrollController,
            ),
      ),
    );
    if (picked != null && picked != _playlist.index) _playIndex(picked);
  }

  /// 全屏：复用同一 [PlayerController] / [VideoController]，进度不丢；
  /// 只有用户点全屏键才进横屏，退出回竖屏（默认）。
  Future<void> _openFullscreen() async {
    if (!mounted) return;
    await _applyBaseOrientations();
    if (!mounted) return;
    await _pc.toggleFullscreen();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveRoomFullscreen(
          controller: _pc,
          videoController: _vc,
          channels: _playlist.channels,
          initialIndex: _playlist.index,
          onSelectChannel: _playIndex,
        ),
      ),
    );
    await _pc.toggleFullscreen();
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _errorSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _pc.dispose();
    super.dispose();
  }

  List<LiveChannel> get _visibleChannels {
    if (_selectedGroup.isEmpty) return _playlist.channels;
    return _playlist.channels
        .where((LiveChannel c) => c.group == _selectedGroup)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final LiveChannel? channel = _channel;
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(channel?.name ?? '直播'),
        actions: <Widget>[
          if (_playlist.hasMultipleRoutes)
            IconButton(
              icon: const Icon(Icons.route_rounded),
              tooltip: '切换线路',
              onPressed: () => _showRoutePicker(context),
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '重新连接',
            onPressed: () {
              _loadTimer?.cancel();
              _loadTimer = null;
              unawaited(_openCurrent());
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Video(
                    controller: _vc,
                    controls: NoVideoControls,
                    fit: BoxFit.contain,
                  ),
                  if (_opening)
                    const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  if (_failed)
                    _RoomFailure(
                      message: _failureMessage,
                      hasMultipleRoutes: _playlist.hasMultipleRoutes,
                      onRetry: () {
                        _loadTimer?.cancel();
                        _loadTimer = null;
                        unawaited(_openCurrent());
                      },
                      onSwitchRoute: _playlist.hasMultipleRoutes
                          ? () => _showRoutePicker(context)
                          : null,
                    )
                  else if (!_opening)
                    RssVideoControls(
                      controller: _pc,
                      videoController: _vc,
                      onToggleFullscreen: () => unawaited(_openFullscreen()),
                    ),
                ],
              ),
            ),
          ),
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
                  tooltip: '上一个频道',
                  onPressed: _playlist.length > 1
                      ? () => _switchBy(-1)
                      : null,
                ),
                Expanded(
                  child: TextButton(
                    onPressed: () => _showChannelPicker(context),
                    child: Text(
                      channel == null
                          ? '选台'
                          : '${channel.name} · ${_playlist.index + 1}/${_playlist.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                if (_playlist.hasMultipleRoutes)
                  TextButton(
                    onPressed: () => _showRoutePicker(context),
                    child: Text(
                      '线路 ${_playlist.route + 1}/${channel!.urls.length}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                IconButton(
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    color: Colors.white,
                  ),
                  tooltip: '下一个频道',
                  onPressed: _playlist.length > 1
                      ? () => _switchBy(1)
                      : null,
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(flex: 31, child: _groupRail(theme)),
                Expanded(flex: 57, child: _channelList(theme)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupRail(ThemeData theme) {
    final List<LiveGroup> groups = widget.result.groups;
    final List<String> entries = <String>[
      '',
      for (final LiveGroup g in groups) g.name,
    ];
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (BuildContext ctx, int i) {
        final String name = entries[i];
        final bool selected = name == _selectedGroup;
        final String label = name.isEmpty
            ? '全部（${_playlist.length}）'
            : name;
        return InkWell(
          onTap: () => setState(() => _selectedGroup = name),
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 2, 6, 2),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _channelList(ThemeData theme) {
    final List<LiveChannel> visible = _visibleChannels;
    if (visible.isEmpty) {
      return const Center(child: Text('这个分组下没有频道'));
    }
    final String? currentKey = _channel?.key;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visible.length,
      itemBuilder: (BuildContext ctx, int i) {
        final LiveChannel c = visible[i];
        final bool selected = c.key == currentKey;
        final int flatIndex = _playlist.indexOfKey(c.key);
        return InkWell(
          onTap: () {
            if (flatIndex >= 0 && flatIndex != _playlist.index) {
              _playIndex(flatIndex);
            }
          },
          child: Container(
            margin: const EdgeInsets.fromLTRB(6, 2, 12, 2),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.secondaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 34,
                  child: Text(
                    '${flatIndex + 1}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                      color: selected
                          ? theme.colorScheme.onSecondaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: selected
                          ? theme.colorScheme.onSecondaryContainer
                          : null,
                    ),
                  ),
                ),
                if (c.urls.length > 1)
                  Text(
                    '${c.urls.length} 线',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 房间内播失败态：显示真实错误 + 重试 / 换线路。
class _RoomFailure extends StatelessWidget {
  final String? message;
  final bool hasMultipleRoutes;
  final VoidCallback onRetry;
  final VoidCallback? onSwitchRoute;

  const _RoomFailure({
    this.message,
    required this.hasMultipleRoutes,
    required this.onRetry,
    this.onSwitchRoute,
  });

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
              Icons.wifi_off_rounded,
              color: Colors.white70,
              size: 32,
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              message ?? '直播暂时中断',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                  label: const Text(
                    '重新连接',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                if (hasMultipleRoutes && onSwitchRoute != null) ...<Widget>[
                  const SizedBox(width: AppTokens.spaceSm),
                  OutlinedButton.icon(
                    onPressed: onSwitchRoute,
                    icon: const Icon(Icons.route_rounded, color: Colors.white),
                    label: const Text(
                      '换线路',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 换台面板：列出全部频道，点选返回下标。
class _ChannelPickerSheet extends StatelessWidget {
  final List<LiveChannel> channels;
  final int currentIndex;
  final ScrollController scrollController;

  const _ChannelPickerSheet({
    required this.channels,
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
            '换台（共 ${channels.length} 个频道）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            itemCount: channels.length,
            itemBuilder: (BuildContext ctx, int i) {
              final LiveChannel c = channels[i];
              final bool selected = i == currentIndex;
              return ListTile(
                dense: true,
                selected: selected,
                leading: Text('${i + 1}'),
                title: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(c.group),
                trailing: c.urls.length > 1
                    ? Text('${c.urls.length} 线')
                    : null,
                onTap: () => Navigator.of(ctx).pop(i),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 直播全屏播放页：复用房间页的同一 [PlayerController] / [VideoController]，
/// 换台不重建引擎、进度不丢。只在用户点全屏键后才进到这里。
class LiveRoomFullscreen extends StatefulWidget {
  final PlayerController controller;
  final VideoController videoController;
  final List<LiveChannel> channels;
  final int initialIndex;
  final ValueChanged<int> onSelectChannel;

  const LiveRoomFullscreen({
    super.key,
    required this.controller,
    required this.videoController,
    required this.channels,
    required this.initialIndex,
    required this.onSelectChannel,
  });

  @override
  State<LiveRoomFullscreen> createState() => _LiveRoomFullscreenState();
}

class _LiveRoomFullscreenState extends State<LiveRoomFullscreen> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.channels.length - 1);
  }

  void _select(int index) {
    if (widget.channels.isEmpty) return;
    final int next = index.clamp(0, widget.channels.length - 1);
    setState(() => _index = next);
    widget.onSelectChannel(next);
  }

  void _switchBy(int delta) {
    if (widget.channels.length < 2) return;
    _select((_index + delta + widget.channels.length) % widget.channels.length);
  }

  Future<void> _showChannelPicker() async {
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (BuildContext ctx, ScrollController scrollController) =>
            _ChannelPickerSheet(
              channels: widget.channels,
              currentIndex: _index,
              scrollController: scrollController,
            ),
      ),
    );
    if (picked != null && picked != _index) _select(picked);
  }

  @override
  Widget build(BuildContext context) {
    final LiveChannel? channel = widget.channels.isEmpty
        ? null
        : widget.channels[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Video(
              controller: widget.videoController,
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
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        channel?.name ?? '直播',
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
                      tooltip: '上一个频道',
                      onPressed: widget.channels.length > 1
                          ? () => _switchBy(-1)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.list_rounded, color: Colors.white),
                      tooltip: '换台',
                      onPressed: _showChannelPicker,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: Colors.white,
                      ),
                      tooltip: '下一个频道',
                      onPressed: widget.channels.length > 1
                          ? () => _switchBy(1)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
            RssVideoControls(
              controller: widget.controller,
              videoController: widget.videoController,
              onToggleFullscreen: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
