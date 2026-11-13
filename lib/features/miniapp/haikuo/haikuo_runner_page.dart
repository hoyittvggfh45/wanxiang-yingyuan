import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wxyy/core/theme/app_tokens.dart';
import 'package:wxyy/core/player/playback_shunt.dart';
import 'package:wxyy/features/player/presentation/playback_shunt_views.dart';

import 'haikuo_codec.dart';
import 'haikuo_program.dart';
import 'haikuo_runtime_html.dart';

/// 海阔小程序运行页。
///
/// 脚本放在本地 HTTP 服务里跑（和内置小程序容器同一套思路）：
/// 页面同源，脚本里的同步 `fetch()` 才能打到 `/__fetch` 由 Dart 侧代理，
/// 绕开 WebView 的跨域限制；点条目时用通道回到原生，媒体地址直接进播放器。
class HaikuoRunnerPage extends StatefulWidget {
  const HaikuoRunnerPage({super.key, required this.program});

  final HaikuoProgram program;

  @override
  State<HaikuoRunnerPage> createState() => _HaikuoRunnerPageState();
}

/// 播放器与运行页之间的递送通道：播放器已在栈顶时，切集解析出的新地址
/// 经它递给播放器，不再另推一页。播放器关闭后控制器失效。
class HaikuoPlayerController {
  void Function({
    required String url,
    required String title,
    required int index,
  })? onDeliver;

  /// 播放器视图登记的切集入口（视图初始化时登记、销毁时清空）。
  Future<void> Function(int index)? onRequestEpisode;

  int currentIndex = 0;

  void deliver({
    required String url,
    required String title,
    required int index,
  }) {
    currentIndex = index;
    onDeliver?.call(url: url, title: title, index: index);
  }

  void requestEpisode(int index) {
    unawaited(onRequestEpisode?.call(index));
  }
}

/// play 消息的去向：播放器已打开时递送（切集），详情页发起时内嵌
/// （海报墙就地变播放器），其余（列表页发起）推一个新播放页。
enum HaikuoPlayRoute { deliver, inline, push }

HaikuoPlayRoute resolvePlayRoute({
  required bool fromDetail,
  required bool playerActive,
}) {
  if (playerActive) return HaikuoPlayRoute.deliver;
  if (fromDetail) return HaikuoPlayRoute.inline;
  return HaikuoPlayRoute.push;
}

/// 藏/恢复详情头项海报墙的桥调用脚本：与运行时 HTML 里的
/// `__haikuoSetInlinePlaying` 对接，桥未定义时短路不报错。
String haikuoInlinePlayingScript(bool on) =>
    'window.__haikuoSetInlinePlaying && '
    'window.__haikuoSetInlinePlaying($on);';

/// 页面（重）载完成时恢复内嵌播放的藏海报墙状态：页面重载后运行时
/// HTML 重新求值，body 上的 `hk-inline-playing` class 随旧 DOM 一起
/// 丢了，内嵌仍在播时必须重发一次桥调用，海报墙才继续藏起；
/// 未在播时不发，避免无故给页面加 class。
Future<void> restoreInlinePlayingOnPageFinished({
  required bool inlineActive,
  required Future<void> Function(String script) runJavaScript,
}) async {
  if (!inlineActive) return;
  try {
    await runJavaScript(haikuoInlinePlayingScript(true));
  } catch (_) {
    // 页面还没准备好时调用失败无妨：只是海报墙显隐，不影响播放本身。
  }
}

/// 一次详情页内嵌播放的参数：播放器槽位据此建 [HaikuoPlayerView]。
class _InlinePlay {
  const _InlinePlay({
    required this.url,
    required this.title,
    required this.series,
    required this.episodes,
    required this.index,
  });

  final String url;
  final String title;
  final String series;
  final List<String> episodes;
  final int index;
}

class _HaikuoRunnerPageState extends State<HaikuoRunnerPage> {
  HttpServer? _server;
  WebViewController? _controller;
  String? _error;
  bool _loading = true;
  // 规则去广告后存下的本地 m3u8（saveFile 发来的内容），由 /__files/<名> 提供给播放器。
  final Map<String, String> _savedFiles = {};
  // 播放器在栈顶时非空：play 消息改为经它递送（切集），不再新开一页。
  HaikuoPlayerController? _playerController;
  // 正在等待切集解析结果：pending 完成（或超时）前收到的 play 消息按此核对。
  Completer<bool>? _pendingEpisodeDelivery;
  int? _pendingEpisodeIndex;
  bool _pendingEpisodeDead = false;
  // 详情页内嵌播放：非空时播放器顶在 WebView 上方，海报墙由 JS 藏起。
  _InlinePlay? _inline;
  bool _inlineFullscreen = false;
  // 代理请求共用一个 HttpClient：连接复用（keep-alive），反复取数
  // 不再每次重建 TCP+TLS；页面关闭时才关掉。
  HttpClient? _httpClient;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    final server = _server;
    _server = null;
    unawaited(server?.close(force: true));
    _httpClient?.close(force: true);
    _httpClient = null;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_handleRequest);
      if (!mounted) return;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF120B20))
        ..setNavigationDelegate(
          NavigationDelegate(
            // 页面（重）载完成：内嵌仍在播时重发藏海报墙状态，
            // 否则重载后详情头项海报墙会在播放器下方重现。
            onPageFinished: (_) => _restoreInlinePlaying(),
          ),
        )
        ..addJavaScriptChannel(
          'HaikuoNative',
          onMessageReceived: _onNativeMessage,
        )
        ..loadRequest(Uri.parse('http://127.0.0.1:${server.port}/'));
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _onNativeMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = {
        for (final entry in decoded.entries) '${entry.key}': entry.value,
      };
    } catch (_) {
      return;
    }
    switch ('${payload['type']}') {
      case 'toast':
        _snack('${payload['text'] ?? ''}');
      case 'saveFile':
        final name = '${payload['name'] ?? ''}';
        if (name.isNotEmpty) {
          _savedFiles[name] = '${payload['content'] ?? ''}';
        }
      case 'play':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        final title = '${payload['title'] ?? widget.program.name}';
        final series = '${payload['series'] ?? ''}';
        final episodes = switch (payload['episodes']) {
          final List list => <String>[
              for (final e in list) '$e',
            ],
          _ => <String>[],
        };
        final index = switch (payload['index']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s),
          _ => null,
        };
        final controller = _playerController;
        final route = resolvePlayRoute(
          fromDetail: payload['detail'] == true,
          playerActive: controller != null,
        );
        if (route == HaikuoPlayRoute.deliver && controller != null) {
          // 播放器已在栈顶：这是切集解析的结果，递给播放器。
          final pending = _pendingEpisodeDelivery;
          final pendingIndex = _pendingEpisodeIndex;
          if (_pendingEpisodeDead) {
            // 超时后才到的迟到解析结果：丢弃，不打扰当前播放。
            _pendingEpisodeDead = false;
            _pendingEpisodeDelivery = null;
            _pendingEpisodeIndex = null;
            return;
          }
          if (pending != null &&
              pendingIndex != null &&
              index != null &&
              index != pendingIndex) {
            // 更新的切集请求已发出，这份是过期结果，丢弃。
            return;
          }
          _pendingEpisodeDelivery = null;
          _pendingEpisodeIndex = null;
          controller.deliver(
            url: url,
            title: title,
            index: index ?? pendingIndex ?? controller.currentIndex,
          );
          if (pending != null && !pending.isCompleted) pending.complete(true);
          return;
        }
        if (route == HaikuoPlayRoute.inline) {
          _openInlinePlayer(
            url,
            title,
            episodes: episodes,
            index: index ?? 0,
            series: series,
          );
          return;
        }
        _openPlayer(
          url,
          title,
          episodes: episodes,
          index: index ?? 0,
          series: series,
        );
      case 'open':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        _openLink(url, '${payload['title'] ?? ''}');
    }
  }

  void _snack(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openPlayer(
    String url,
    String title, {
    List<String> episodes = const [],
    int index = 0,
    String series = '',
  }) async {
    final controller = HaikuoPlayerController()..currentIndex = index;
    _playerController = controller;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HaikuoPlayPage(
          url: url,
          title: title,
          seriesTitle: series,
          episodes: episodes,
          initialIndex: index,
          controller: controller,
          onSelectEpisode: _selectEpisode,
        ),
      ),
    );
    // 播放器已关闭：控制器失效，未完成的切集等待直接判失败。
    if (identical(_playerController, controller)) {
      _playerController = null;
      final pending = _pendingEpisodeDelivery;
      _pendingEpisodeDelivery = null;
      _pendingEpisodeIndex = null;
      _pendingEpisodeDead = false;
      if (pending != null && !pending.isCompleted) pending.complete(false);
    }
  }

  /// 详情页内嵌播放：播放器就地顶在 WebView 上方，海报墙由 JS 藏起，
  /// 不推新页面。切集与等待复用同一套控制器/pending 机制。
  void _openInlinePlayer(
    String url,
    String title, {
    List<String> episodes = const [],
    int index = 0,
    String series = '',
  }) {
    final controller = HaikuoPlayerController()..currentIndex = index;
    _playerController = controller;
    setState(() {
      _inline = _InlinePlay(
        url: url,
        title: title,
        series: series,
        episodes: episodes,
        index: index,
      );
      _inlineFullscreen = false;
    });
    unawaited(_setInlinePlaying(true));
  }

  void _closeInlinePlayer() {
    _playerController = null;
    final pending = _pendingEpisodeDelivery;
    _pendingEpisodeDelivery = null;
    _pendingEpisodeIndex = null;
    _pendingEpisodeDead = false;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    if (!mounted) return;
    setState(() {
      _inline = null;
      _inlineFullscreen = false;
    });
    unawaited(_setInlinePlaying(false));
  }

  /// 通知运行时藏起/恢复详情头项海报墙。页面还没准备好时调用
  /// 失败无妨：只是海报墙显隐，不影响播放本身。
  Future<void> _setInlinePlaying(bool on) async {
    try {
      await _controller?.runJavaScript(haikuoInlinePlayingScript(on));
    } catch (_) {
      // 忽略
    }
  }

  /// 内嵌仍在播时重发藏海报墙的桥调用（页面重载后恢复用）。
  void _restoreInlinePlaying() {
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      restoreInlinePlayingOnPageFinished(
        inlineActive: _inline != null,
        runJavaScript: controller.runJavaScript,
      ),
    );
  }

  /// 顶栏刷新：重载页面后先发一次藏海报墙状态（可能打在旧页上，
  /// 丢了无妨），页面就绪回调里再按内嵌状态补一次。
  void _reloadPage() {
    final controller = _controller;
    if (controller == null) return;
    unawaited(controller.reload());
    _restoreInlinePlaying();
  }

  /// 播放器点选第 [index] 集：经运行时重走该集的 lazy 解析链路，
  /// 解析出的 play 消息回流到 [_onNativeMessage] 再递给播放器。
  /// 返回解析是否在 30 秒内递达（超时返回 false，迟到结果会被丢弃）。
  Future<bool> _selectEpisode(int index) async {
    final controller = _controller;
    if (controller == null || _playerController == null) return false;
    final completer = Completer<bool>();
    _pendingEpisodeDelivery = completer;
    _pendingEpisodeIndex = index;
    _pendingEpisodeDead = false;
    try {
      await controller.runJavaScript(
        'window.__haikuoPlayEpisode && window.__haikuoPlayEpisode($index);',
      );
    } catch (_) {
      if (identical(_pendingEpisodeDelivery, completer)) {
        _pendingEpisodeDelivery = null;
        _pendingEpisodeIndex = null;
      }
      return false;
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      if (identical(_pendingEpisodeDelivery, completer)) {
        // 保留 pending 标记为已死：迟到的解析结果到达时丢弃。
        _pendingEpisodeDead = true;
      }
      return false;
    }
  }

  Future<void> _openLink(String url, String title) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _HaikuoWebPage(url: url, title: title),
      ),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/') {
        final payload = _programPayload();
        final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
        final html =
            haikuoRuntimeHtml.replaceAll('__PROGRAM_B64__', encoded).replaceAll(
                  '__TITLE__',
                  const HtmlEscape().convert(widget.program.name),
                );
        request.response.headers.contentType = ContentType.html;
        request.response.write(html);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/__fetch') {
        await _proxy(request);
        return;
      }
      if (request.uri.path.startsWith('/__files/')) {
        final name = Uri.decodeComponent(
          request.uri.path.substring('/__files/'.length),
        );
        final content = _savedFiles[name];
        if (content == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
            charset: 'utf-8',
          );
          request.response.write(content);
        }
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // 连接已经断了，忽略
      }
    }
  }

  Map<String, dynamic> _programPayload() {
    final program = widget.program;
    Map<String, dynamic> rule = const {};
    if (program.rawJson.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(program.rawJson);
        if (decoded is Map) {
          rule = {
            for (final entry in decoded.entries) '${entry.key}': entry.value,
          };
        }
      } catch (_) {
        rule = const {};
      }
    }
    return {
      'name': program.name,
      'script': program.script,
      'url': program.url,
      'kind': program.kind.name,
      'rule': rule,
    };
  }

  Future<void> _proxy(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final target = params['u'] ?? '';
    final method = (params['m'] ?? 'GET').toUpperCase();
    final body = params['b'] ?? '';
    Map<String, String> headers = const {};
    final rawHeaders = params['h'];
    if (rawHeaders != null && rawHeaders.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawHeaders);
        if (decoded is Map) {
          headers = {
            for (final entry in decoded.entries)
              '${entry.key}': '${entry.value}',
          };
        }
      } catch (_) {
        headers = const {};
      }
    }
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      response.write(jsonEncode({'code': 0, 'body': ''}));
      await response.close();
      return;
    }
    final merged = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      ...headers,
    };
    try {
      // 共用客户端：同一主机的连接复用，不再每次取数都重建 TCP+TLS。
      // UA 走下面逐请求的头设置，不再写客户端默认值（多请求会互相串）。
      final client = _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 15);
      final uri = Uri.parse(target);
      final req = await client.openUrl(method, uri).timeout(
        const Duration(seconds: 25),
      );
      merged.forEach((key, value) {
        if (value.isEmpty) return;
        if (key.toLowerCase() == 'content-length') return;
        try {
          req.headers.set(key, value);
        } catch (_) {
          // 个别头 WebView 设置不进去，跳过
        }
      });
      if (method != 'GET' && method != 'HEAD' && body.isNotEmpty) {
        req.add(utf8.encode(body));
      }
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final bytes = await resp.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      response.write(
        jsonEncode({
          'code': resp.statusCode,
          'body': HaikuoCodec.decodeText(bytes.takeBytes()),
        }),
      );
      await response.close();
    } catch (error) {
      response.write(jsonEncode({'code': 0, 'body': '', 'error': '$error'}));
      await response.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _inline == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_inlineFullscreen) {
          setState(() => _inlineFullscreen = false);
          return;
        }
        _closeInlinePlayer();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF120B20),
        appBar: AppBar(
          title: Text(widget.program.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _reloadPage,
            ),
          ],
        ),
        body: _error != null
            ? _RunnerError(message: _error!)
            : _loading || _controller == null
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, constraints) {
                  final inline = _inline;
                  return Column(
                    children: [
                      // 播放器槽位始终在树里（未播放时高度为 0），保证
                      // WebView 的树位置不变，切入切出内嵌播放不重载页面。
                      SizedBox(
                        height: inline == null
                            ? 0
                            : _inlineFullscreen
                            ? constraints.maxHeight
                            : constraints.maxWidth * 9 / 16,
                        child: inline == null
                            ? null
                            : HaikuoPlayerView(
                                url: inline.url,
                                title: inline.title,
                                seriesTitle: inline.series,
                                episodes: inline.episodes,
                                initialIndex: inline.index,
                                controller: _playerController,
                                onSelectEpisode: _selectEpisode,
                                fullscreen: _inlineFullscreen,
                                onFullscreenChanged: (value) => setState(
                                  () => _inlineFullscreen = value,
                                ),
                                onClose: _closeInlinePlayer,
                              ),
                      ),
                      Expanded(child: WebViewWidget(controller: _controller!)),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _RunnerError extends StatelessWidget {
  const _RunnerError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 42),
            const SizedBox(height: AppTokens.spaceMd),
            Text('小程序没能启动：$message', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// 外部链接页：脚本里 `open(url)` 打开普通网页时用。
class _HaikuoWebPage extends StatefulWidget {
  const _HaikuoWebPage({required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<_HaikuoWebPage> createState() => _HaikuoWebPageState();
}

class _HaikuoWebPageState extends State<_HaikuoWebPage> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(
            widget.title.isEmpty ? widget.url : widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: WebViewWidget(controller: _controller),
      );
}

/// 海阔播放器视图：播放器本体（media_kit + 自带最小控件层），不带脚手架。
/// 推页播放（[HaikuoPlayPage]）与详情页内嵌播放（运行页顶部的播放器槽位）共用同一套。
/// 自带最小控件层（播放/暂停、进度条、倍速、选集、全屏、播完自动连播），
/// 不依赖魔蚁的 PlayerControls / PlayerInteractions / NetworkSpeedTracker /
/// AppOrientationController / AppTheme：全屏只用 SystemChrome（横屏锁定 +
/// 沉浸模式，退出时恢复系统默认方向），不显示网速，没有滑动手势。
/// 全屏状态由宿主持有：宿主据此决定布局与返回键行为，视图只负责
/// 上报切换意图并在值变化时落地方向/系统 UI 副作用。
/// 协议分流在开播前决策：novel/pics 显示分流视图、不打开媒体；
/// 音频照常打开、只把视频画面换成音频封面。
class HaikuoPlayerView extends StatefulWidget {
  const HaikuoPlayerView({
    super.key,
    required this.url,
    required this.title,
    this.seriesTitle = '',
    this.episodes = const [],
    this.initialIndex = 0,
    this.controller,
    this.onSelectEpisode,
    this.headers = const {},
    this.onStateChange,
    required this.fullscreen,
    required this.onFullscreenChanged,
    this.onClose,
    this.onCurrentChanged,
    this.playerFactory,
    this.videoBuilder,
  });

  final String url;
  final String title;

  /// 剧名（详情头项标题），有则显示在顶栏标题前。
  final String seriesTitle;

  /// 当前详情的全部选集标题（按序），为空表示只有一个可播地址。
  final List<String> episodes;

  final int initialIndex;
  final HaikuoPlayerController? controller;

  /// 点选第 index 集时调用：回到运行页解析该集地址，返回是否按时递达。
  final Future<bool> Function(int index)? onSelectEpisode;

  /// 取流请求头（蜘蛛回的 header 原样带上，如 Referer/UA）。
  final Map<String, String> headers;

  /// 播放状态变化回调（小程序播放桥用）：每次播/停切换与整秒
  /// 进度变化时上报 {opened, url, title, playing, positionMs,
  /// durationMs}；不传则不上报。
  final ValueChanged<Map<String, dynamic>>? onStateChange;

  /// 是否全屏：宿主持有并据此布局。
  final bool fullscreen;

  /// 全屏切换意图：点全屏/返回键退出全屏时上报，宿主改值后视图跟随。
  final ValueChanged<bool> onFullscreenChanged;

  /// 非全屏时点返回：传了就调它（内嵌播放关闭播放器），不传则退栈。
  final VoidCallback? onClose;

  /// 当前集/标题变化时通知宿主（播放页下方的选集条据此高亮）。
  final void Function(int index, String title)? onCurrentChanged;

  /// 测试注入播放器：默认直接 new Player()。
  final Player Function()? playerFactory;

  /// 测试注入视频画面：默认真实 Video + VideoController；传了它
  /// 就不建 Video 画面（假播放器没有平台 handle）。
  final WidgetBuilder? videoBuilder;

  @override
  State<HaikuoPlayerView> createState() => _HaikuoPlayerViewState();
}

/// 媒体播放页：海阔小程序返回直链（m3u8 / mp4）时用它播。
///
/// 本体是 [HaikuoPlayerView]，下方另有选集条；选集上下文由运行时随
/// play 消息带上；切集时经 [onSelectEpisode] 回到运行页重走该集的
/// lazy 解析，解析出的地址由 [controller] 递回本页。
class HaikuoPlayPage extends StatefulWidget {
  const HaikuoPlayPage({
    super.key,
    required this.url,
    required this.title,
    this.seriesTitle = '',
    this.episodes = const [],
    this.initialIndex = 0,
    this.controller,
    this.onSelectEpisode,
    this.headers = const {},
    this.onStateChange,
    this.playerFactory,
    this.videoBuilder,
  });

  final String url;
  final String title;

  /// 剧名（详情头项标题），有则显示在顶栏标题前。
  final String seriesTitle;

  /// 当前详情的全部选集标题（按序），为空表示只有一个可播地址。
  final List<String> episodes;

  final int initialIndex;
  final HaikuoPlayerController? controller;

  /// 点选第 index 集时调用：回到运行页解析该集地址，返回是否按时递达。
  final Future<bool> Function(int index)? onSelectEpisode;

  /// 取流请求头（蜘蛛回的 header 原样带上，如 Referer/UA）。
  final Map<String, String> headers;

  /// 播放状态变化回调（小程序播放桥用）：每次播/停切换与整秒
  /// 进度变化时上报 {opened, url, title, playing, positionMs,
  /// durationMs}；不传则不上报。
  final ValueChanged<Map<String, dynamic>>? onStateChange;

  /// 测试注入播放器：默认直接 new Player()。
  final Player Function()? playerFactory;

  /// 测试注入视频画面：默认真实 Video + VideoController。
  final WidgetBuilder? videoBuilder;

  @override
  State<HaikuoPlayPage> createState() => _HaikuoPlayPageState();
}

class _HaikuoPlayerViewState extends State<HaikuoPlayerView> {
  static const List<double> _speeds = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
    3.0,
  ];

  late final Player _player = widget.playerFactory?.call() ?? Player();
  late final VideoController _video = VideoController(_player);
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Timer? _hideTimer;
  int _lastReportedSecond = -1;
  bool _lastReportedPlaying = false;

  late String _url = widget.url;
  late String _title = widget.title;
  late int _index = widget.initialIndex;
  double _speed = 1.0;
  String? _error;
  bool _resolving = false;
  bool _showControls = true;
  double? _dragValue;

  /// 协议分流决策：novel/pics 时显示分流视图、不打开媒体；
  /// audio 时照常打开媒体、只把视频画面换成音频封面。
  PlaybackDecision? _shunt;

  /// 当前是否为音频模式（分流判为音频）。
  bool get _isAudioMode => _shunt?.kind == PlaybackKind.audio;

  bool get _hasEpisodes => widget.episodes.isNotEmpty;
  bool get _hasPrev => _hasEpisodes && _index > 0;
  bool get _hasNext => _hasEpisodes && _index < widget.episodes.length - 1;

  String get _displayTitle {
    final series = widget.seriesTitle;
    if (series.isEmpty) return _title;
    if (_title.isEmpty || _title == series) return series;
    return '$series · $_title';
  }

  @override
  void initState() {
    super.initState();
    if (_index < 0 || _index >= widget.episodes.length) _index = 0;
    widget.controller?.onDeliver = _onDelivered;
    widget.controller?.onRequestEpisode = _switchEpisode;
    _errorSubscription = _player.stream.error.listen((error) {
      if (!mounted || _error != null) return;
      setState(() => _error = error);
    });
    _positionSubscription = _player.stream.position.listen((_) {
      _reportState();
    });
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (completed && _hasNext) _switchEpisode(_index + 1);
    });
    _playingSubscription = _player.stream.playing.listen((_) {
      _reportState();
    });
    _open();
    _scheduleHide();
  }

  /// 给 onStateChange 上报当前状态：播/停切换必报，进度只在整秒
  /// 变化时报，避免每帧刷回调。
  void _reportState() {
    final report = widget.onStateChange;
    if (report == null || !mounted) return;
    final state = _player.state;
    final second = state.position.inSeconds;
    if (second == _lastReportedSecond &&
        state.playing == _lastReportedPlaying) {
      return;
    }
    _lastReportedSecond = second;
    _lastReportedPlaying = state.playing;
    report(<String, dynamic>{
      'opened': true,
      'url': _url,
      'title': _displayTitle,
      'playing': state.playing,
      'positionMs': state.position.inMilliseconds,
      'durationMs': state.duration.inMilliseconds,
    });
  }

  @override
  void didUpdateWidget(HaikuoPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fullscreen != oldWidget.fullscreen) {
      unawaited(_applyFullscreen(widget.fullscreen));
    }
  }

  @override
  void dispose() {
    widget.controller?.onDeliver = null;
    widget.controller?.onRequestEpisode = null;
    _hideTimer?.cancel();
    unawaited(_errorSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_player.dispose());
    if (widget.fullscreen) unawaited(_restoreSystemUi());
    super.dispose();
  }

  Future<void> _open() async {
    // 分流（开播前）：地址命中 novel:// 或 pics:// 时进分流视图，
    // 不送解码；音频记决策后照常打开（只换画面）。
    final PlaybackDecision decision = classifyPlayback(
      url: _url,
      headers: widget.headers,
      fallbackTitle: _displayTitle,
    );
    if (decision.kind == PlaybackKind.novel ||
        decision.kind == PlaybackKind.pics) {
      if (!mounted) return;
      setState(() {
        _shunt = decision;
        _error = null;
      });
      return;
    }
    if (mounted) setState(() => _shunt = decision.shunted ? decision : null);
    try {
      await _player.open(Media(_url, httpHeaders: widget.headers));
      await _player.setRate(_speed);
      _reportState();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  void _onDelivered({
    required String url,
    required String title,
    required int index,
  }) {
    if (!mounted) return;
    setState(() {
      _url = url;
      _title = title;
      _index = index;
      _resolving = false;
      _error = null;
      _shunt = null;
    });
    widget.onCurrentChanged?.call(index, title);
    unawaited(_open());
  }

  Future<void> _togglePlayback() async {
    await _player.playOrPause();
    _pokeControls();
  }

  Future<void> _seekTo(Duration position) async {
    await _player.seek(position);
  }

  void _pokeControls() {
    if (!mounted) return;
    setState(() => _showControls = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      // 暂停时控件常驻，播着才自动藏。
      if (!_player.state.playing) return;
      setState(() => _showControls = false);
    });
  }

  // 全屏状态由宿主持有：这里只上报切换意图，方向与系统 UI 的
  // 副作用在 didUpdateWidget 收到新值后由 _applyFullscreen 落地；
  // 视图在全屏中被直接卸载时，dispose 里的 _restoreSystemUi 兜底。
  Future<void> _toggleFullscreen() async {
    widget.onFullscreenChanged(!widget.fullscreen);
  }

  Future<void> _applyFullscreen(bool fullscreen) async {
    if (fullscreen) {
      try {
        await SystemChrome.setPreferredOrientations(
          const <DeviceOrientation>[
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ],
        );
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.immersiveSticky,
        );
      } catch (_) {
        // 平台不支持方向锁定，忽略。
      }
      _pokeControls();
    } else {
      await _restoreSystemUi();
    }
  }

  Future<void> _restoreSystemUi() async {
    try {
      // 空列表 = 恢复系统默认方向（与底包播放器/阅读器的退出口径一致）。
      await SystemChrome.setPreferredOrientations(
        const <DeviceOrientation>[],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {
      // 平台不支持，忽略。
    }
  }

  void _back() {
    if (widget.fullscreen) {
      widget.onFullscreenChanged(false);
      return;
    }
    final close = widget.onClose;
    if (close != null) {
      close();
      return;
    }
    Navigator.of(context).maybePop();
  }

  Future<void> _switchEpisode(int index) async {
    final select = widget.onSelectEpisode;
    if (_resolving || select == null) return;
    if (index < 0 || index >= widget.episodes.length) return;
    if (index == _index) return;
    setState(() => _resolving = true);
    final ok = await select(index);
    if (!mounted) return;
    if (!ok) {
      setState(() => _resolving = false);
      _toast('解析超时，请重试');
    }
    // 解析成功时地址经 controller 递回 _onDelivered，那里清 _resolving。
  }

  void _toast(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _showEpisodes() async {
    if (!_hasEpisodes) {
      _toast('该内容只有一个可播地址');
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusLg),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.seriesTitle.isEmpty ? '选集' : widget.seriesTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.episodes.length} 集',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.episodes.length,
                itemBuilder: (context, i) {
                  final current = i == _index;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      current ? Icons.play_arrow : Icons.play_circle_outline,
                      color: current ? Colors.orangeAccent : Colors.white70,
                    ),
                    title: Text(
                      widget.episodes[i],
                      style: TextStyle(
                        color: current ? Colors.orangeAccent : Colors.white,
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(i),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    _pokeControls();
    if (selected != null) unawaited(_switchEpisode(selected));
  }

  Future<void> _showSpeed() async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusLg),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '倍速',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final rate in _speeds)
                    ListTile(
                      dense: true,
                      title: Text(
                        '${rate}x',
                        style: TextStyle(
                          color: rate == _speed
                              ? Colors.orangeAccent
                              : Colors.white,
                        ),
                      ),
                      trailing: rate == _speed
                          ? const Icon(
                              Icons.check,
                              color: Colors.orangeAccent,
                            )
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(rate),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    _pokeControls();
    if (selected == null) return;
    setState(() => _speed = selected);
    await _player.setRate(selected);
  }

  Widget _videoArea() {
    final PlaybackDecision? shunt = _shunt;
    // 分流视图：小说/图片不送解码，顶栏保留返回与标题；下方选集条
    // 照常切集（新地址经递达重走分流决策）。
    if (shunt != null &&
        (shunt.kind == PlaybackKind.novel ||
            shunt.kind == PlaybackKind.pics)) {
      final Widget body;
      if (shunt.blocked) {
        // 地址固定、重试无法改变结果，不给重试按钮。
        body = ShuntBlockedView(reason: shunt.blockedReason!);
      } else if (shunt.kind == PlaybackKind.novel) {
        body = ShuntNovelView(content: shunt.content!, title: _displayTitle);
      } else {
        body = ShuntPicsView(content: shunt.content!, title: _displayTitle);
      }
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          body,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: Colors.white,
                      tooltip: '返回',
                      onPressed: _back,
                    ),
                    Expanded(
                      child: Text(
                        _displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: () {
            setState(() => _showControls = !_showControls);
            if (_showControls) _scheduleHide();
          },
          // 音频模式：视频画面换成封面区，控制层共用同一套。
          child: _isAudioMode
              ? ShuntAudioCover(title: _displayTitle)
              : widget.videoBuilder?.call(context) ??
                  Video(
                    controller: _video,
                    fit: BoxFit.contain,
                    controls: (_) => const SizedBox.shrink(),
                  ),
        ),
        if (_error != null)
          Container(
            color: Colors.black54,
            padding: const EdgeInsets.all(AppTokens.spaceXl),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '播放失败：$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: AppTokens.spaceLg),
                  FilledButton(
                    onPressed: () {
                      setState(() => _error = null);
                      unawaited(_open());
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          )
        else if (_resolving)
          const ColoredBox(
            color: Colors.black45,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: AppTokens.spaceMd),
                  Text('正在解析…', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          ),
        if (_error == null && _showControls) _controlsOverlay(),
      ],
    );
  }

  Widget _controlsOverlay() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: Colors.white,
                    tooltip: '返回',
                    onPressed: _back,
                  ),
                  Expanded(
                    child: Text(
                      _displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Center(
          child: StreamBuilder<bool>(
            stream: _player.stream.playing,
            initialData: _player.state.playing,
            builder: (context, snapshot) {
              final playing = snapshot.data ?? false;
              return IconButton(
                iconSize: 56,
                icon: Icon(
                  playing
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_filled_rounded,
                  color: Colors.white,
                ),
                onPressed: _togglePlayback,
              );
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _seekBar(),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.skip_previous_rounded),
                        color: Colors.white,
                        tooltip: '上一集',
                        onPressed: _hasPrev && !_resolving
                            ? () => _switchEpisode(_index - 1)
                            : null,
                      ),
                      StreamBuilder<bool>(
                        stream: _player.stream.playing,
                        initialData: _player.state.playing,
                        builder: (context, snapshot) {
                          final playing = snapshot.data ?? false;
                          return IconButton(
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                            color: Colors.white,
                            tooltip: playing ? '暂停' : '播放',
                            onPressed: _togglePlayback,
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next_rounded),
                        color: Colors.white,
                        tooltip: '下一集',
                        onPressed: _hasNext && !_resolving
                            ? () => _switchEpisode(_index + 1)
                            : null,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _showSpeed,
                        child: Text(
                          '${_speed}x',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      TextButton(
                        onPressed: _showEpisodes,
                        child: const Text(
                          '选集',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          widget.fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                        ),
                        color: Colors.white,
                        tooltip: widget.fullscreen ? '退出全屏' : '全屏',
                        onPressed: _toggleFullscreen,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _seekBar() {
    return StreamBuilder<Duration>(
      stream: _player.stream.duration,
      initialData: _player.state.duration,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final totalSeconds = duration.inSeconds.toDouble();
        return StreamBuilder<Duration>(
          stream: _player.stream.position,
          initialData: _player.state.position,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final shown = (_dragValue ?? position.inSeconds.toDouble())
                .clamp(0.0, totalSeconds)
                .toDouble();
            final max = totalSeconds <= 0 ? 1.0 : totalSeconds;
            return Row(
              children: [
                Expanded(
                  child: Slider(
                    value: shown,
                    max: max,
                    onChangeStart: (_) => _hideTimer?.cancel(),
                    onChanged: totalSeconds <= 0
                        ? null
                        : (value) => setState(() => _dragValue = value),
                    onChangeEnd: (value) {
                      setState(() => _dragValue = null);
                      unawaited(
                        _seekTo(Duration(seconds: value.toInt())),
                      );
                      _pokeControls();
                    },
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Text(
                  '${_formatDuration(position)} / ${_formatDuration(duration)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static String _formatDuration(Duration value) {
    final total = value.inSeconds < 0 ? 0 : value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$mm:$ss';
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) => _videoArea();
}

class _HaikuoPlayPageState extends State<HaikuoPlayPage> {
  bool _fullscreen = false;
  late int _currentIndex = _clampIndex(widget.initialIndex);
  late String _currentTitle = widget.title;

  int _clampIndex(int value) {
    if (value < 0 || value >= widget.episodes.length) return 0;
    return value;
  }

  bool get _hasEpisodes => widget.episodes.isNotEmpty;

  String get _displayTitle {
    final series = widget.seriesTitle;
    if (series.isEmpty) return _currentTitle;
    if (_currentTitle.isEmpty || _currentTitle == series) return series;
    return '$series · $_currentTitle';
  }

  Widget _playerView() {
    return HaikuoPlayerView(
      url: widget.url,
      title: widget.title,
      seriesTitle: widget.seriesTitle,
      episodes: widget.episodes,
      initialIndex: widget.initialIndex,
      controller: widget.controller,
      onSelectEpisode: widget.onSelectEpisode,
      headers: widget.headers,
      onStateChange: widget.onStateChange,
      fullscreen: _fullscreen,
      onFullscreenChanged: (value) => setState(() => _fullscreen = value),
      onCurrentChanged: (index, title) => setState(() {
        _currentIndex = index;
        _currentTitle = title;
      }),
      playerFactory: widget.playerFactory,
      videoBuilder: widget.videoBuilder,
    );
  }

  Widget _belowVideo() {
    if (!_hasEpisodes) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _displayTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Wrap(
            spacing: AppTokens.spaceSm,
            runSpacing: AppTokens.spaceSm,
            children: [
              for (var i = 0; i < widget.episodes.length; i++)
                ChoiceChip(
                  label: Text(widget.episodes[i]),
                  selected: i == _currentIndex,
                  // 经控制器请播放器视图切集，复用视图的解析等待与防重入。
                  onSelected: (_) => widget.controller?.requestEpisode(i),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _fullscreen = false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        // 播放器视图固定在 Column 第 0 位、只改槽位高度，
        // 全屏切换不换树位置，Player 不重建、不重播。
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                children: [
                  SizedBox(
                    height: _fullscreen
                        ? constraints.maxHeight
                        : constraints.maxWidth * 9 / 16,
                    child: _playerView(),
                  ),
                  if (!_fullscreen) Expanded(child: _belowVideo()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
