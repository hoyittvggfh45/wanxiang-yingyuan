import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart'
    as android_webview;
import 'package:wxyy/core/models/episode.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/theme/app_tokens.dart';
import 'package:wxyy/features/player/presentation/video_player_screen.dart';

import 'mini_app_ad_filter.dart';
import 'mini_app_bridge.dart';
import 'mini_app_manifest.dart';
import 'mini_app_runtime.dart';
import 'mini_app_sdk.dart';
import 'mini_app_settings.dart';
import 'mini_app_sources.dart';

class MiniAppHostPage extends StatefulWidget {
  const MiniAppHostPage({
    super.key,
    required this.manifest,
    required this.runtime,
    required this.settings,
    this.launchOptions = const <String, dynamic>{},
  });

  final MiniAppManifest manifest;
  final MiniAppRuntime runtime;
  final MiniAppSettings settings;
  final Map<String, dynamic> launchOptions;

  @override
  State<MiniAppHostPage> createState() => _MiniAppHostPageState();
}

class _MiniAppHostPageState extends State<MiniAppHostPage> {
  WebViewController? _controller;
  MiniAppInstance? _instance;
  MiniAppBridge? _bridge;

  /// player.getState 的快照：只诚实记录“播放页是否打开过/已关闭”
  /// （opened）与本次地址标题。底包没有全局播放状态，playing /
  /// positionMs / durationMs 填 false / 0 表示未知，不是真实进度。
  Map<String, dynamic> _playerState = const {'opened': false};
  String? _error;
  bool _loading = true;
  bool _showLoadingOverlay = false;
  String _loadingMessage = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    widget.runtime.markBackground(widget.manifest.appId);
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final instance = await widget.runtime.ensureRunning(widget.manifest);
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      late final MiniAppBridge bridge;
      bridge = MiniAppBridge(
        manifest: widget.manifest,
        appDir: instance.dir,
        prefs: prefs,
        launchOptions: widget.launchOptions,
        sourceProvider: _wiredSourceProvider(),
        callbacks: MiniAppBridgeCallbacks(
          evaluateJavascript: (js) async {
            final controller = _controller;
            if (controller != null) {
              await controller.runJavaScript(js);
            }
          },
          showToast: (message) {
            if (!mounted || message.isEmpty) return;
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(message)),
            );
          },
          showLoading: (message) {
            if (!mounted) return;
            setState(() {
              _showLoadingOverlay = true;
              _loadingMessage = message ?? '';
            });
          },
          hideLoading: () {
            if (!mounted) return;
            setState(() => _showLoadingOverlay = false);
          },
          confirm: ({required title, required content}) async {
            if (!mounted) return false;
            final result = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(content),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确定'),
                  ),
                ],
              ),
            );
            return result ?? false;
          },
          actionSheet: (items) async {
            if (!mounted) return -1;
            final result = await showModalBottomSheet<int>(
              context: context,
              builder: (context) => SafeArea(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) => ListTile(
                    title: Text(items[index]),
                    onTap: () => Navigator.pop(context, index),
                  ),
                ),
              ),
            );
            return result ?? -1;
          },
          navigateTo: (path) async {
            final controller = _controller;
            final base = _instance?.baseUrl;
            if (controller == null || base == null) return;
            final clean = path.startsWith('/') ? path.substring(1) : path;
            await controller.loadRequest(Uri.parse('$base/$clean'));
          },
          navigateBack: () async {
            final controller = _controller;
            if (controller == null) return;
            if (await controller.canGoBack()) {
              await controller.goBack();
            } else if (mounted) {
              Navigator.pop(context);
            }
          },
          exit: () {
            if (mounted) Navigator.pop(context);
          },
          openMiniApp: (appId) async {
            if (!mounted) return;
            final base = await widget.runtime.resolveUrl(appId);
            if (!mounted) return;
            if (base == null) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(content: Text('目标小程序未安装')),
              );
              return;
            }
            final installed = await widget.runtime.store.listInstalled();
            final target = installed.where((e) => e.appId == appId).firstOrNull;
            if (target == null || !mounted) return;
            await Navigator.push<void>(
              context,
              MaterialPageRoute<void>(
                builder: (_) => MiniAppHostPage(
                  manifest: target,
                  runtime: widget.runtime,
                  settings: widget.settings,
                ),
              ),
            );
          },
          resolveMiniAppUrl: (appId) => widget.runtime.resolveUrl(appId),
          log: (message) => debugPrint(message),
          openPlayer: _openPlayer,
          playerState: () => Map<String, dynamic>.from(_playerState),
        ),
      );
      _bridge = bridge;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..addJavaScriptChannel(
          MiniAppSdkScript.channelName,
          onMessageReceived: (message) {
            unawaited(bridge.handleChannelMessage(message.message));
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) => _decideNavigation(request.url),
            onPageStarted: (_) {
              unawaited(_injectSdk());
            },
            onPageFinished: (_) async {
              if (!mounted) return;
              setState(() => _loading = false);
              await _injectSdk();
              await bridge.emit('app.show');
            },
            onWebResourceError: (error) {
              debugPrint('小程序页面资源错误：${error.description}');
            },
          ),
        )
        ..loadRequest(Uri.parse(instance.server.entryUrl()));
      if (!mounted) return;
      setState(() {
        _instance = instance;
        _controller = controller;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  /// source.* 宿主实现：经 Provider 取底包源仓库与媒体服务；
  /// 拿不到时传未接通的 Provider（列表为空、调用报不可用），不崩溃。
  MiniAppSourceProvider _wiredSourceProvider() {
    SourceRepository? repository;
    MediaApiService? service;
    try {
      repository = context.read<SourceRepository>();
    } catch (_) {
      repository = null;
    }
    try {
      service = context.read<MediaApiService>();
    } catch (_) {
      service = null;
    }
    return HostMiniAppSourceProvider(
      repository: repository,
      service: service,
    );
  }

  /// 播放器桥的宿主实现：直链目标进底包播放页（直链模式）；
  /// 网页/解析线路目标需要网页嗅探，当前移植尚未接通嗅探，
  /// 诚实告知用户后返回 false，不编假地址、不静默失败。
  /// 返回 true 表示确实打开了播放器。
  Future<bool> _openPlayer(MiniAppPlayTarget target) async {
    if (!mounted) return false;
    if (target.isSniff) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('该地址需要网页嗅探取流，当前版本尚未接通嗅探，无法播放'),
        ),
      );
      return false;
    }
    final title = target.title.isEmpty ? widget.manifest.name : target.title;
    _playerState = <String, dynamic>{
      'opened': true,
      'url': target.url,
      'title': title,
      'playing': false,
      'positionMs': 0,
      'durationMs': 0,
    };
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerScreen(
          title: title,
          episode: Episode(
            id: target.url,
            title: title,
            url: target.url,
          ),
          sourceId: 'miniapp',
          itemId: 'miniapp_${target.url.hashCode}',
          directUrl: target.url,
          directHeaders: target.headers.isEmpty ? null : target.headers,
        ),
      ),
    );
    _playerState = const {'opened': false};
    unawaited(_bridge?.emit('player.close', {'url': target.url}));
    return true;
  }

  Future<NavigationDecision> _decideNavigation(String url) async {
    if (url.startsWith('miniapp://')) {
      final rest = url.substring('miniapp://'.length);
      final appId = rest.split('/').first;
      if (appId.isNotEmpty) {
        final base = await widget.runtime.resolveUrl(appId);
        if (!mounted) return NavigationDecision.prevent;
        if (base == null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('目标小程序未安装')),
          );
          return NavigationDecision.prevent;
        }
        final installed = await widget.runtime.store.listInstalled();
        final target = installed.where((e) => e.appId == appId).firstOrNull;
        if (target != null && mounted) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) => MiniAppHostPage(
                manifest: target,
                runtime: widget.runtime,
                settings: widget.settings,
              ),
            ),
          );
        }
      }
      return NavigationDecision.prevent;
    }
    if (widget.settings.adFilter && miniAppShouldBlockUrl(url)) {
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  Future<void> _injectSdk() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(MiniAppSdkScript.script);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.manifest.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: controller == null
                ? null
                : () => unawaited(controller.reload()),
          ),
        ],
      ),
      body: _buildBody(controller),
    );
  }

  Widget _buildBody(WebViewController? controller) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 48),
              const SizedBox(height: AppTokens.spaceMd),
              const Text('小程序启动失败'),
              const SizedBox(height: AppTokens.spaceSm),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppTokens.spaceLg),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _loading = true;
                  });
                  _start();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final webView = defaultTargetPlatform == TargetPlatform.android
        ? WebViewWidget.fromPlatformCreationParams(
            params: android_webview.AndroidWebViewWidgetCreationParams(
              controller: controller.platform,
              displayWithHybridComposition: widget.settings.hybridComposition,
            ),
          )
        : WebViewWidget(controller: controller);
    return Stack(
      children: [
        webView,
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
        if (_showLoadingOverlay)
          Container(
            color: Colors.black45,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                if (_loadingMessage.isNotEmpty) ...[
                  const SizedBox(height: AppTokens.spaceMd),
                  Text(
                    _loadingMessage,
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
