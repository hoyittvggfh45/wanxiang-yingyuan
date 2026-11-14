import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';
import 'package:wxyy/generated/app_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../../app.dart';
import '../../core/article/article_reading_preferences.dart';
import '../../core/download/download_file_system.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/ohos_doc_file_system.dart';
import '../../core/download/saf_download_file_system.dart';
import '../../core/local/saf_bridge.dart' show normalizeSafTreeUri;
import '../../core/platform/ohos_public_storage.dart' show isOhosDocPath;
import '../../core/download/download_settings.dart';
import '../../core/download/download_storage.dart';
import '../../core/favorites/favorites_manager.dart';
import '../../core/history/history_manager.dart';
import '../../core/local/local_content_manager.dart';
import '../../core/locale/locale_controller.dart';
import '../../core/models/hive_adapters.dart';
import '../../core/network/network_config_service.dart';
import '../../core/network/source_network_override_store.dart';
import '../../core/novel/novel_toc_store.dart';
import '../../core/utils/app_log.dart';
import '../../core/resolver/resolver_registry.dart';
import '../../core/rss/rss_manager.dart';
import '../../core/rss/rss_update_checker.dart';
import '../../core/history/media_watched_manager.dart';
import '../../core/history/media_playback_position_manager.dart';
import '../../core/scraper/media_api_service.dart';
import '../../core/services/bangumi/bangumi_ech_proxy.dart';
import '../../core/services/bangumi/bangumi_proxy_config.dart';
import '../../core/services/source_library_bookmarks.dart';
import '../../core/services/source_library_subscription.dart';
import '../../core/storage/box_lock_probe.dart';
import '../../core/settings/general_settings.dart';
import '../../core/storage/cache_auto_clean.dart';
import '../../core/storage/platform_path_compat.dart';
import '../../core/storage/storage_boxes.dart';
import '../../core/widgets/app_loading_indicator.dart';
import '../../core/services/source_repository.dart';
import '../../core/services/config_loader.dart';
import '../../core/scraper/cookie_store.dart';
import '../../core/scraper/http_fetcher.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/theme/system_wallpaper_color.dart';
import '../shuyuan/presentation/shuyuan_novel_resolver.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/update/update_manager.dart';
import '../../core/update/update_settings.dart';

/// Holds all artifacts produced during app initialization.
///
/// These are created during the splash phase and then injected into the
/// widget tree via [MultiProvider] once initialization completes.
class InitResult {
  final SourceRepository sourceRepo;
  final ResolverRegistry registry;
  final MediaApiService mediaService;
  final DownloadManager downloadManager;
  final FavoritesManager favoritesManager;
  final HistoryManager historyManager;
  final RssManager rssManager;
  final RssUpdateChecker rssUpdateChecker;
  final MediaWatchedManager mediaWatchedManager;
  final MediaPlaybackPositionManager mediaPlaybackPositionManager;
  final LocalContentManager localContentManager;
  final NetworkConfigService networkConfigService;

  const InitResult({
    required this.sourceRepo,
    required this.registry,
    required this.mediaService,
    required this.downloadManager,
    required this.favoritesManager,
    required this.historyManager,
    required this.rssManager,
    required this.rssUpdateChecker,
    required this.mediaWatchedManager,
    required this.mediaPlaybackPositionManager,
    required this.localContentManager,
    required this.networkConfigService,
  });
}

/// Splash screen that drives full app initialization before handing off to
/// [App]. While initialization is in flight a logo with a progress indicator
/// is shown; on failure a retry UI is offered.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Future<InitResult>? _initFuture;

  /// Hive 适配器注册表是进程级静态状态，而 [_initialize] 可能被重试
  /// （或开发期 hot restart）再次执行；重复注册会抛
  /// `HiveError: There is already a TypeAdapter for typeId 0`。
  static bool _adaptersRegistered = false;

  /// 是否已把源仓库的变更监听绑到 ECH 层（同 [_adaptersRegistered] 的重复执行防护：
  /// [SourceRepository] 每次启动都会新建，重复绑定只会让同一份快照被写两次）。
  static bool _sourceRepoListenerBound = false;

  /// 主题状态。在初始化管线**之前**就恢复持久化偏好，使加载页 / 错误页
  /// 与主界面同色——否则深色偏好下加载页会先闪一段白底。
  /// 初始化完成后同一实例注入 Provider，避免主题被重置。
  final ThemeController _themeController = ThemeController();

  @override
  void initState() {
    super.initState();
    _themeController.load();
    _initFuture = _initialize();
  }

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  /// Runs the full initialization pipeline previously hosted in [main].
  /// Order matches the original main() exactly: Hive init,
  /// adapter registration, box opening, source loading, resolver/media setup,
  /// download manager, then favorites/history/rss/article-feed managers.
  Future<InitResult> _initialize() async {
    try {
      return await _initializeInner().timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException('启动初始化超过 45 秒，请重试'),
      );
    } on Object catch (e, s) {
      debugPrint('[Splash] 初始化失败: $e\n$s');
      rethrow;
    }
  }

  Future<InitResult> _initializeInner() async {
    // 鸿蒙壁纸主色：main() 已在首帧前预取（进程内缓存），这里同步注入即可，
    // 保证加载页首帧即用壁纸色，避免主题从默认色过渡到壁纸色。取不到时保持
    // 默认主题，回前台后由 app.dart 补读。
    _themeController.setSystemDynamicSeed(SystemWallpaperColor.latestSeed);

    final appDir = await getApplicationDocumentsDirectory();
    // Hive 初始化是启动硬前提：15 秒硬上限，超时即失败走重试页，
    // 绝不在此无限等待（用户实报的“进不去界面”首先要排除这一步）。
    await Hive.initFlutter(appDir.path).timeout(const Duration(seconds: 15));

    if (!_adaptersRegistered) {
      Hive.registerAdapter(HiveMediaItemAdapter());
      Hive.registerAdapter(HiveEpisodeAdapter());
      Hive.registerAdapter(HivePluginConfigAdapter());
      Hive.registerAdapter(HiveReadingProgressAdapter());
      Hive.registerAdapter(HiveFavoriteAdapter());
      Hive.registerAdapter(HiveDownloadTaskAdapter());
      Hive.registerAdapter(HiveDanmakuCacheAdapter());
      Hive.registerAdapter(HiveRssFeedAdapter());
      Hive.registerAdapter(HiveSettingsAdapter());
      _adaptersRegistered = true;
    }

    await Future.wait(<Future<void>>[
      for (final name in kStorageBoxNames)
        _openBoxResilient(name, appDir.path),
    ]);

    // 跨平台备份自修复：外来平台写进来的路径型配置（下载 / 导出 / 截图目录）
    // 在本机没有对应实现，必须在挑选文件系统后端之前拉回默认值，否则会按错
    // 平台构造后端并打断启动（详见 storage/platform_path_compat.dart）。
    await _guarded('修复外来平台路径', repairImportedPlatformPathsOnStartup);

    // 加载内置源（资源包）+ 用户导入源。单步失败只记日志、降级继续，
    // 不让某一步卡住整个启动（见 [_guarded]）。
    final sourceRepo = SourceRepository();
    await _guarded('加载内置源', sourceRepo.loadBuiltins);
    await _guarded('加载导入源', sourceRepo.loadImported);
    // 加载持久化的镜像选择
    await _guarded('加载镜像选择', ConfigLoader.instance.init);
    // 持久化 Cookie 回填：冷启动后从本地 Hive 读取已验证站点的会话 Cookie，
    // 避免每次冷启动都重新过验证（「反复验证 → 高频请求 → IP 被封」首要根因）。
    await _guarded('Cookie 回填', CookieStore.init);
    await _guarded('加载持久化 Cookie', HttpFetcher.instance.loadPersistedCookies);
    // 网络配置：全局档案 + 源级用户覆盖，须在任何网络使用前就绪，
    // 使 splash 之后的抓取/下载/同步即时走真实代理/DNS 档案。
    await _guarded('源级网络覆盖', SourceNetworkOverrideStore.instance.init);
    await _guarded('网络配置', NetworkConfigService.instance.load);
    final registry = ResolverRegistry.instance;
    // 注入书源解析器（ShuyuanNovelResolver），避免 core 反向依赖 feature 层。
    // 必须在 registry 被使用前注册；ShuyuanNovelResolver 内部自建 WebBook/XiaoshuoHttp。
    registerShuyuanResolver(ShuyuanNovelResolver.new);
    final mediaService = MediaApiService(registry);

    // Download base path: 优先用用户配置的路径；未配置（空串或旧版
    // `D:/Downloads` 遗留值，在 Android 上无效）时回退到平台相关默认目录。
    // `content://` 树 URI（Android SAF 用户目录）走 SafFileSystem。
    final downloadSettings = await DownloadSettingsStore().load();
    String configured = downloadSettings.downloadPath;
    // 外来平台路径兜底（repairImportedPlatformPathsOnStartup 已清过一轮，
    // 这里再守一道）：本机没有对应文件系统后端的路径一律回落平台默认目录。
    // 典型：鸿蒙读到 Android 备份里的 content:// → SAF 原生通道不存在 →
    // MissingPluginException 直接打断启动，用户表现为「导入备份后打不开」。
    if (!isPathSupportedOnThisPlatform(configured)) {
      AppLog.instance.w('[下载路径自修复] "$configured" 不属于本平台，重置为默认目录');
      configured = await defaultDownloadPath();
      await DownloadSettingsStore()
          .save(downloadSettings.copyWith(downloadPath: configured));
    }
    // 启动自修复：历史版本曾把 tree id 的 `%3A` 错误解码成 `:` 并持久化
    // （写盘用未编码 root，读取纠正为已编码 → 定位不一致 → 下载后打不开）。
    // 检测到 content:// 路径被污染则立即写回规范化值，一次性永久修复。
    if (configured.startsWith('content://')) {
      final String normalized = normalizeSafTreeUri(configured);
      if (normalized != configured) {
        configured = normalized;
        await DownloadSettingsStore()
            .save(downloadSettings.copyWith(downloadPath: normalized));
      }
    }
    // 启动自修复（Android 10+ 分区存储）：历史版本经 file_picker 持久化过的
    // 「真实路径」（如 /storage/emulated/0/Download/万象影院）在分区存储下
    // dart:io 不可写（open failed: EACCES），表现为每次下载都失败且无法自愈。
    // 这类路径（/storage/、/sdcard 下且不在应用私有 Android/data 目录内）
    // 一律重置为平台默认目录；用户仍可在下载设置重选（现在的选择器走 SAF）。
    if (!kIsWeb &&
        !configured.startsWith('content://') &&
        !isUnsetDownloadPath(configured) &&
        await _isUnwritableScopedStoragePath(configured)) {
      AppLog.instance.w('[下载路径自修复] "$configured" 在分区存储下不可写，重置为平台默认目录');
      configured = await defaultDownloadPath();
      await DownloadSettingsStore()
          .save(downloadSettings.copyWith(downloadPath: configured));
    }
    final DownloadFileSystem downloadFs;
    if (configured.startsWith('content://')) {
      downloadFs = SafFileSystem(configured);
    } else if (isOhosDocPath(configured)) {
      // 鸿蒙公共下载目录（`ohosdoc://`）：读写全部走原生通道。
      downloadFs = OhosDocFileSystem(configured);
    } else {
      final String downloadBasePath;
      if (!isUnsetDownloadPath(configured)) {
        downloadBasePath = configured;
      } else {
        downloadBasePath = await defaultDownloadPath();
      }
      downloadFs = PathProviderFileSystem(downloadBasePath);
    }
    final downloadManager = DownloadManager(
      storage: DownloadStorage(),
      fs: downloadFs,
      service: mediaService,
      sourceRepo: sourceRepo,
    );
    try {
      await downloadManager.init();
    } on Object catch (e) {
      // 最后一道防线：下载后端（目录后端 / 原生通道）异常也不该让应用打不开。
      // 换平台默认目录重建，仍失败则带着已加载的任务列表继续（下载暂不可用，
      // 但设置页可达，用户能自修复或恢复备份）。
      AppLog.instance.w('[下载] 初始化失败，改用默认目录重建: $e');
      try {
        final String fallback = await defaultDownloadPath();
        // 先落盘再重建：init 内部会重读设置，顺序反了会读到旧的外来路径。
        await DownloadSettingsStore()
            .save(downloadSettings.copyWith(downloadPath: fallback));
        downloadManager.fs = PathProviderFileSystem(fallback);
        await downloadManager.init();
      } on Object catch (e2) {
        AppLog.instance.w('[下载] 默认目录初始化仍失败（降级继续启动）: $e2');
      }
    }

    // 分叉版本不做在线更新检查（原作者更新源已移除），启动链上不再初始化
    // 更新管理器、不发起任何更新请求。

    // 应用内更新管理器初始化（加载镜像/自动检查设置）：守卫式，失败不挡启动。
    await _guarded('更新管理器', UpdateManager.instance.init);

    // 启动时自动检查更新（静默，不阻塞初始化；未配置发布源地址时立即返回）。
    unawaited(_autoCheckUpdate());

    // 缓存自动清理（年龄 + 容量双策略）：初始化完成后后台执行一次，
    // 不阻塞首帧；开关与阈值见高级设置「缓存管理」。
    unawaited(_runCacheAutoClean());

    // 各管理器初始化改为并行 + 单步超时守卫：此前串行 await，任何一步
    // 卡住都会让启动页无限转圈（用户实报症状之一）。单步失败只记日志、
    // 该管理器以空态继续，首页仍可达。
    final favoritesManager = FavoritesManager();
    final historyManager = HistoryManager();
    final rssManager = RssManager();
    final rssUpdateChecker = RssUpdateChecker(rssManager: rssManager);
    final mediaWatchedManager = MediaWatchedManager();
    final mediaPlaybackPositionManager = MediaPlaybackPositionManager();
    final localContentManager = LocalContentManager();
    await Future.wait(<Future<void>>[
      _guarded('收藏', favoritesManager.init),
      _guarded('历史', historyManager.init),
      _guarded('RSS', rssManager.init),
      _guarded('RSS 更新检查', rssUpdateChecker.init),
      _guarded('已看进度', mediaWatchedManager.init),
      _guarded('播放位置', mediaPlaybackPositionManager.init),
      _guarded('本地内容', localContentManager.init),
    ]);
    // ECH 本地代理配置与恢复（通用网络能力，与账号登录无关，保留）。
    await _guarded('Bangumi 代理配置', BangumiProxyConfig.load);
    // 冷启动恢复 ECH 本地代理（对应参考 useCachedResources 的
    // restoreEchProxy + setupEchLifecycle）。原生未实现时安全降级。
    // 先把源列表交给 ECH 层：三套作用域里的「源级 ECH」需要扫描每个源的
    // network.ech 声明，而生命周期观察者（resume 重建）没有 BuildContext。
    BangumiEchProxy.instance.setSourceConfigs(sourceRepo.all);
    // 源列表本身变化（导入 / 编辑 / 删除 / 启停源）同样会改变源级 ECH 作用域：
    // 跟随刷新快照并重下发。`setSourceConfigs` 只换快照不下发，避免 setter 里做 I/O。
    if (!_sourceRepoListenerBound) {
      _sourceRepoListenerBound = true;
      sourceRepo.addListener(() {
        BangumiEchProxy.instance.setSourceConfigs(sourceRepo.all);
        unawaited(BangumiEchProxy.instance.applyEchScope());
      });
    }
    await _guarded(
      'ECH 代理恢复',
      () => BangumiEchProxy.instance.restoreEchProxy(
        BangumiProxyConfig.instance.echEnabled,
      ),
      timeout: const Duration(seconds: 5),
    );
    BangumiEchProxy.instance.setupEchLifecycle();
    // 通用设置（启动界面 / 日期格式 / 年龄限制）需在首页构建前就绪。
    await _guarded('通用设置', GeneralSettingsStore.instance.load);
    // 年龄限制开关注入源仓库：开启时成人分级源不参与任何内容入口。
    sourceRepo.setAgeRestrictionEnabled(
      GeneralSettingsStore.instance.settings.ageRestrictionEnabled,
    );

    return InitResult(
      sourceRepo: sourceRepo,
      registry: registry,
      mediaService: mediaService,
      downloadManager: downloadManager,
      favoritesManager: favoritesManager,
      historyManager: historyManager,
      rssManager: rssManager,
      rssUpdateChecker: rssUpdateChecker,
      mediaWatchedManager: mediaWatchedManager,
      mediaPlaybackPositionManager: mediaPlaybackPositionManager,
      localContentManager: localContentManager,
      networkConfigService: NetworkConfigService.instance,
    );
  }

  /// 启动时自动检查更新（静默）。
  ///
  /// 检测到新版本时：
  /// - 始终缓存到 UpdateManager（About 页可显示）；
  /// - 若用户开启了「自动下载更新」，且满足 WiFi（如需）与应用内下载条件，
  /// 则静默下载安装包，不打断首次进入应用。
  Future<void> _autoCheckUpdate() async {
    final settings = await UpdateSettingsStore().load();
    if (!settings.autoCheck) return;
    final manager = UpdateManager.instance;
    final release = await manager.checkForUpdate(
      timeout: const Duration(seconds: 15),
    );
    if (release == null) return;
    String current = '0.0.0';
    try {
      current = (await PackageInfo.fromPlatform()).version;
    } on Object {
      // 读取失败按 0.0.0 处理，不阻断自动更新。
    }
    if (!manager.isNewer(release.tagName, current)) return;
    // 触发自动下载（内部按 autoDownload / wifiOnlyAutoDownload /
    // inAppDownload 设置决定是否真正下载）。
    await manager.maybeAutoDownload(release);
  }

  /// 单步初始化守卫：超时或抛错只记日志、降级继续，绝不卡住启动。
  ///
  /// 启动链上每一步（源加载、Cookie、网络配置、各管理器、ECH 恢复、
  /// 更新管理器、通用设置）都经此守卫：任何一步出问题，首页仍可达，
  /// 出问题的管理器以空态运行，用户可在设置里自修复或重试启动。
  Future<void> _guarded(
    String step,
    Future<void> Function() run, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      await run().timeout(timeout);
    } on Object catch (e) {
      AppLog.instance.w('[启动] $step 失败或超时（降级继续）: $e');
    }
  }

  /// 打开单个 Hive box；单个 box 损坏不应让整个应用停在「加载失败」页。
  ///
  /// 导入备份 / 大批量写盘途中进程被杀、磁盘写满，都可能留下校验失败的 box
  /// 文件，[Hive.openBox] 会抛 [HiveError]。此时把疑似损坏的文件改名留档
  /// （不直接删，便于事后排查），再重建一个空 box；非 Hive 自身错误（例如
  /// 权限）只跳过、绝不碰文件。
  ///
  /// 开盒前先过 [probeBoxLock]：锁被滞留的旧引擎/进程持有时，[Hive.openBox]
  /// 内部的阻塞式文件锁会冻住事件循环（超时与重试界面全部饿死），故探到
  /// 争用直接抛 [BoxLockContended]，绝不进 `openBox`，让启动失败快速、
  /// 可见、可重试。
  Future<void> _openBoxResilient(String name, String hivePath) async {
    await probeBoxLock(hivePath, name);
    try {
      await Hive.openBox(name);
      return;
    } on HiveError catch (e) {
      AppLog.instance.w('[存储] 打开 box "$name" 失败（疑似文件损坏）: $e');
    } on Object catch (e) {
      // 非 Hive 自身错误（权限 / 路径不可用等）：不碰磁盘文件，跳过该 box。
      AppLog.instance.w('[存储] 打开 box "$name" 失败（已跳过）: $e');
      return;
    }
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      final File file = File('${dir.path}/$name.hive');
      if (await file.exists()) {
        final String archived =
            '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
        await file.rename(archived);
        AppLog.instance.w('[存储] 疑似损坏的 box 文件已留档: $archived');
      }
      await Hive.deleteBoxFromDisk(name);
      await Hive.openBox(name);
      AppLog.instance.i('[存储] box "$name" 已重建（原文件不可读，已留档）');
    } on Object catch (e) {
      AppLog.instance.w('[存储] 重建 box "$name" 失败（跳过该 box）: $e');
    }
  }

  void _retry() {
    setState(() {
      _initFuture = _initialize();
    });
  }



  /// 启动缓存自动清理：按设置（年龄上限 + 容量上限）清理派生缓存，
  /// 失败静默（缓存清理绝不能影响冷启动可用性）。
  Future<void> _runCacheAutoClean() async {
    try {
      await CacheAutoCleaner.runStartupClean();
      await cleanExpiredDanmakuCache();
    } on Object catch (e) {
      AppLog.instance.w('[缓存自动清理] 启动清理失败: $e');
    }
  }

  /// 判断路径是否为「分区存储（Android 10+）下 dart:io 不可写」的公共存储
  /// 真实路径。
  ///
  /// 判定（仅 Android 调用）：路径位于公共外部存储（`/storage/`、`/sdcard`）
  /// 且不在应用私有外部目录（`getExternalStorageDirectory()`，即
  /// `Android/data/<pkg>/`）内。这类路径自 targetSdk 30 起普通应用一律
  /// EACCES，Persisted 下来只会让每次下载都失败。应用私有目录（含
  /// `Android/data` 与内部 `getApplicationDocumentsDirectory`，后者不在
  /// `/storage/` 下）以及任何非公共存储路径均返回 false。
  Future<bool> _isUnwritableScopedStoragePath(String path) async {
    final String p = path.replaceAll('\\', '/');
    const publicPrefixes = <String>['/storage/', '/sdcard/'];
    final bool isPublic =
        publicPrefixes.any((pre) => p.startsWith(pre) || p == pre);
    if (!isPublic) return false;
    // /sdcard 是 /storage/emulated/0 的符号链接，统一到 /storage/ 比较。
    final String normalized = p.startsWith('/sdcard/')
        ? '/storage/emulated/0/${p.substring('/sdcard/'.length)}'
        : p;
    try {
      final Directory? appExt = await getExternalStorageDirectory();
      if (appExt != null && normalized.startsWith(appExt.path)) return false;
    } on Object {
      // 取不到私有目录时按保守处理：公共存储路径一律视为不可写。
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<InitResult>(
      future: _initFuture,
      builder: (context, snapshot) {
        // Done + success: inject providers and hand off to App.
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasData) {
          final result = snapshot.data!;
          return MultiProvider(
            providers: [
              ChangeNotifierProvider<ThemeController>.value(
                value: _themeController,
              ),
              ChangeNotifierProvider<SourceRepository>.value(
                  value: result.sourceRepo),
              Provider<ResolverRegistry>.value(value: result.registry),
              Provider<MediaApiService>.value(value: result.mediaService),
              ChangeNotifierProvider<DownloadManager>.value(
                  value: result.downloadManager),
              ChangeNotifierProvider<FavoritesManager>.value(
                  value: result.favoritesManager),
              ChangeNotifierProvider<HistoryManager>.value(
                  value: result.historyManager),
              ChangeNotifierProvider<RssManager>.value(
                  value: result.rssManager),
              ChangeNotifierProvider<RssUpdateChecker>.value(
                  value: result.rssUpdateChecker),
              ChangeNotifierProvider<MediaWatchedManager>.value(
                  value: result.mediaWatchedManager),
              ChangeNotifierProvider<MediaPlaybackPositionManager>.value(
                  value: result.mediaPlaybackPositionManager),
              ChangeNotifierProvider<LocalContentManager>.value(
                  value: result.localContentManager),
              ChangeNotifierProvider<NetworkConfigService>.value(
                  value: result.networkConfigService),
              ChangeNotifierProvider<ArticleReadingPreferencesNotifier>(
                create: (_) => ArticleReadingPreferencesNotifier(),
              ),
              ChangeNotifierProvider<SourceLibraryBookmarks>(
                create: (_) => SourceLibraryBookmarks()..load(),
              ),
              ChangeNotifierProvider<SourceLibrarySubscription>(
                create: (_) => SourceLibrarySubscription()..load(),
              ),
              ChangeNotifierProvider<LocaleController>(
                create: (_) => LocaleController()..load(),
              ),
              ChangeNotifierProvider<NovelTocStore>(
                create: (_) => NovelTocStore(),
              ),
            ],
            child: const App(),
          );
        }

        // Loading or error: wrap in a minimal MaterialApp so that
        // Theme.of(context) and AppLocalizations.of(context) resolve.
        // 主题取自 [_themeController]（已恢复持久化偏好）而非
        // ThemeData.light/dark，且显式传 themeMode——否则用户选了深色但
        // 系统为浅色时，这段加载期会渲染成白底。
        return ListenableBuilder(
          listenable: _themeController,
          builder: (BuildContext context, Widget? _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _themeController.lightTheme(),
            darkTheme: _themeController.darkTheme(),
            themeMode: _themeController.mode,
            // 与 app.dart 一致的全局系统栏兜底：加载/报错页也保持
            // 透明导航栏，避免启动期颜色跳变。
            builder: (BuildContext context, Widget? child) {
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: AppTheme.systemOverlayStyle(Theme.of(context)),
                child: child!,
              );
            },
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: const [
              Locale('zh'),
              Locale('en'),
            ],
            home: snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasError
                ? _ErrorView(
                    error: snapshot.error,
                    onRetry: _retry,
                  )
                : const _SplashView(),
          ),
        );
      },
    );
  }
}

/// Logo + progress indicator shown while initialization is in flight.
/// No text is displayed (per spec, no l10n keys added for splash).
class _SplashView extends StatelessWidget {
  const _SplashView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 圆角应用图标（与关于页一致）：启动加载时即呈现圆角品牌图标。
            ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusXl),
              child: Image.asset(
                'assets/icon/icon.png',
                width: 120,
                height: 120,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: AppTokens.spaceXl),
            // 灵动三点弹跳加载（替代转圈），与全应用加载动效统一。
            AppBouncingDots(color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

/// Error UI shown when initialization fails. Offers a retry button that
/// re-runs the initialization pipeline.
class _ErrorView extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;

  const _ErrorView({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.space2xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_rounded,
                size: 64,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: AppTokens.spaceLg),
              Text(
                l10n.loadFailed,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              // 真实失败原因必须可见：只显示通用「加载失败」时，用户与排查
              // 方都无法区分超时、锁争用、权限等不同根因。
              if (error != null) ...<Widget>[
                const SizedBox(height: AppTokens.spaceMd),
                Text(
                  error.toString(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: AppTokens.spaceXl),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(l10n.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
