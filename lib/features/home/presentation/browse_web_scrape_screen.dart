import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wxyy/generated/app_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/episode.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/platform/file_exporter.dart';
import '../../../core/platform/platform_service.dart';
import '../../../core/pygen/auto_site_entry.dart';
import '../../../core/pygen/onekey_py_service.dart';
import '../../../core/pygen/scrape_format_gen.dart';
import '../../../core/scraper/scrape_open_router.dart';
import '../../../core/scraper/verification_detector.dart';
import '../../../core/scraper/web_scrape_service.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_error_state.dart';
import '../../../core/widgets/app_segmented_tabs.dart';
import '../../../core/widgets/app_url_input_bar.dart';
import '../../../features/verification/presentation/webview_verification_screen.dart';
import '../../manga/presentation/manga_online_list_screen.dart';
import '../../media/presentation/media_online_list_screen.dart';
import '../../novel/presentation/novel_online_list_screen.dart';
import '../../player/presentation/video_player_screen.dart';
import 'package:wxyy/core/navigation/app_page_route.dart';
import '../../../core/widgets/app_glass_bar.dart';

/// 网页爬取（浏览页占位功能之一）。
///
/// 五种模式：通用 / 小说 / 漫画 / 视频 / 文章。结果按模式差异化展示，
/// 命中验证特征时通过 [navigateToVerification] 引导用户完成验证后重试。
class BrowseWebScrapeScreen extends StatefulWidget {
  final ScrapeMode? initialMode;
  const BrowseWebScrapeScreen({super.key, this.initialMode});

  @override
  State<BrowseWebScrapeScreen> createState() => _BrowseWebScrapeScreenState();
}

class _BrowseWebScrapeScreenState extends State<BrowseWebScrapeScreen> {
  ScrapeMode _mode = ScrapeMode.general;
  final TextEditingController _urlCtl = TextEditingController();
  bool _loading = false;
  String? _error;
  ScrapeResult? _result;
  final OneKeyPyService _pyService = OneKeyPyService();
  bool _generating = false;
  String _genProgress = '';
  String? _genError;
  OneKeyCodeResult? _genResult;
  bool _registering = false;
  bool _registered = false;

  /// 当前选中的生成格式（默认按爬取模式定，见 [_defaultFormatForMode]）。
  ScrapeGenFormat _selectedFormat = ScrapeGenFormat.py;

  /// 非 py 格式的生成产物（py 产物仍走 [_genResult]，两者互斥显示）。
  GeneratedFormatArtifact? _formatArtifact;

  /// 格式可用性缓存：按（结果对象，当前模式）记忆，避免每次 build
  /// 都重新解析页面 HTML。
  List<FormatAvailability>? _availCache;
  ScrapeResult? _availCacheResult;
  ScrapeMode? _availCacheMode;

  /// 爬取提交序号：每次提交递增；自动进站链路的每步 await 后核对，
  /// 过期（用户已重新爬取）则中止，不导航、不注册。
  int _scrapeSeq = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialMode != null) _mode = widget.initialMode!;
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  Future<void> _scrape(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) return;
    // 模式与序号在提交时锁定：结果与自动进站决策都按本次提交的模式走，
    // 不受提交后用户切换模式影响。
    final ScrapeMode mode = _mode;
    final int seq = ++_scrapeSeq;
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _genProgress = '';
      _genError = null;
      _genResult = null;
      _registered = false;
      _selectedFormat = _defaultFormatForMode(mode);
      _formatArtifact = null;
    });
    try {
      final result = await WebScrapeService.instance.scrape(url, mode);
      if (mounted) {
        setState(() {
          _result = result;
          _loading = false;
        });
        unawaited(_autoEnterSite(result, mode, seq));
      }
    } on VerificationRequiredException catch (e) {
      if (!mounted) return;
      final ok = await navigateToVerification(context, url: url, exception: e);
      if (ok && mounted) {
        _scrape(url);
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _scrapeUrl(String url) {
    _urlCtl.text = url;
    _scrape(url);
  }

  /// 爬取成功后自动进站点（仅视频 / 通用模式）：同一基址已注册过则
  /// 直接打开；否则生成 py → 过现有校验 → 自动注册 → 打开浏览页。
  /// 生成失败、校验不过、结构未识别时不建站，留在结果页如实报错，
  /// 手动生成 / 导出 / 注册卡片原样保留作兜底。[seq] 过期（用户已
  /// 重新爬取）时中止，不导航、不注册。
  Future<void> _autoEnterSite(
    ScrapeResult result,
    ScrapeMode mode,
    int seq,
  ) async {
    if (!isAutoEnterSiteMode(mode)) return;
    final String base = OneKeyPyService.originOf(result.url);
    if (base.isEmpty) return;
    final SourceRepository repo = context.read<SourceRepository>();
    final ExistingSiteCheck existing =
        await checkExistingSiteForBase(repo, base);
    if (!mounted || seq != _scrapeSeq || !identical(_result, result)) return;
    switch (planAutoSiteEntry(mode: mode, existing: existing)) {
      case AutoSiteAction.skip:
        return;
      case AutoSiteAction.openExisting:
        _openSiteBrowse(existing.active!);
        return;
      case AutoSiteAction.showInactiveNotice:
        _showScrapeMessage(
          '该站点已注册，但当前未启用：${existing.inactive!.name}。请在源列表里启用后再打开。',
        );
        return;
      case AutoSiteAction.generateAndOpen:
        break;
    }
    setState(() {
      _generating = true;
      _genProgress = '正在为该站点生成 py…';
      _genError = null;
      _genResult = null;
      _registered = false;
    });
    final OneKeyCodeResult? gen;
    try {
      gen = await _runGenerate(result);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
    if (!mounted || seq != _scrapeSeq || !identical(_result, result)) {
      if (mounted) setState(() => _genProgress = '');
      return;
    }
    if (gen == null) return; // 失败原因已写进生成卡片，留在结果页
    setState(() {
      _genResult = gen;
      _genProgress = '';
    });
    if (!isRecognizedGeneration(gen)) {
      // 结构未识别：不自动建站，生成结果留在卡片里供手动导出/注册。
      _showScrapeMessage('未能识别出该站点的结构，未自动建站；可在下方手动导出或注册生成的 py。');
      return;
    }
    final OneKeyGenerateResult? res = await _registerGeneratedCode(gen);
    if (!mounted || res == null || seq != _scrapeSeq) return;
    _openSiteBrowse(res.config);
  }

  /// 打开已注册站点的浏览页：复用媒体区“点源进浏览”同一入口
  ///（分类 / 列表 / 详情 / 播放全套走 py 引擎），不新写浏览界面。
  void _openSiteBrowse(PluginConfig source) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => MediaOnlineListScreen(initialSource: source),
      ),
    );
  }

  void _showScrapeMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 经主播放器直链模式打开：视频正常播、音频走分流音频视图、
  /// novel:// 与 pics:// 载荷走分流小说 / 图片视图，不新造末端。
  /// [episodeId] 同时作剧集 id 与地址（视频为地址本身，小说/图片为
  /// 爬取页地址）；打开失败报真原因，不静默吞。
  Future<void> _openInMainPlayer({
    required String title,
    required String episodeId,
    required String directUrl,
    required String itemId,
    Map<String, String>? headers,
  }) async {
    try {
      await Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => VideoPlayerScreen(
            title: title,
            episode: Episode(id: episodeId, title: title, url: episodeId),
            sourceId: 'webscrape',
            itemId: itemId,
            directUrl: directUrl,
            directHeaders: headers,
          ),
        ),
      );
    } on Object catch (e) {
      _showScrapeMessage('打开失败：$e');
    }
  }

  /// 小说 / 文章：正文拼 novel:// 载荷走主播放器分流进小说视图，
  /// 不再写临时文本文件、不走简易查看器。
  Future<void> _openNovelText(String title) async {
    final ScrapeResult? result = _result;
    if (result == null || result.paragraphs.isEmpty) return;
    final String text = result.paragraphs.join('\n\n');
    if (text.trim().isEmpty) {
      _showScrapeMessage('没有取到正文内容');
      return;
    }
    await _openInMainPlayer(
      title: title,
      episodeId: result.url,
      directUrl: buildScrapeNovelPayload(title: title, content: text),
      itemId: 'webscrape_novel_${result.url.hashCode}',
    );
  }

  /// 漫画：图列拼 pics:// 载荷走主播放器分流进图片浏览视图
  ///（翻页 / 缩放 / 计数由分流视图提供），防盗链带爬取页 Referer。
  Future<void> _openImages(String title) async {
    final ScrapeResult? result = _result;
    if (result == null || result.imageUrls.isEmpty) return;
    await _openInMainPlayer(
      title: title,
      episodeId: result.url,
      directUrl: buildScrapePicsPayload(result.imageUrls),
      itemId: 'webscrape_pics_${result.url.hashCode}',
      headers: <String, String>{'Referer': result.url},
    );
  }

  Future<void> _launch(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).loadFailed)),
        );
      }
    }
  }

  /// 视频：媒体地址进主播放器直链模式（分流自动接管其中音频地址）；
  /// 内嵌页地址不硬塞播放器，走外部浏览器兜底并明示原因；
  /// 无法打开的地址报真原因。
  Future<void> _openVideoInApp(ScrapedVideo video, AppLocalizations l10n) async {
    final ScrapeResult? result = _result;
    final String title = result?.pageTitle ?? l10n.scrapeResultTitle;
    switch (classifyScrapeVideoUrl(video.url, fromIframe: video.fromIframe)) {
      case ScrapeVideoRoute.player:
        await _openInMainPlayer(
          title: title,
          episodeId: video.url,
          directUrl: video.url,
          itemId: 'webscrape_${video.url.hashCode}',
          // 直链常校验 Referer：缺省用爬取页地址兜底（与嗅探同一做法）。
          headers: result == null
              ? null
              : <String, String>{'Referer': result.url},
        );
      case ScrapeVideoRoute.browser:
        _showScrapeMessage('该地址是内嵌播放页，已用浏览器打开');
        await _launch(video.url);
      case ScrapeVideoRoute.unsupported:
        _showScrapeMessage('该地址无法播放（不是可播放的媒体地址）');
    }
  }

  /// 一键生成 py：依据本次爬取实际拿到的数据（地址、HTML、标题、链接），
  /// 不再让用户输网址重新探测。只产出代码，默认不注册。
  Future<void> _generatePy() async {
    final ScrapeResult? result = _result;
    if (result == null || _generating) return;
    setState(() {
      _generating = true;
      _genProgress = '正在分析爬取数据…';
      _genError = null;
      _genResult = null;
      _formatArtifact = null;
      _registered = false;
    });
    try {
      final OneKeyCodeResult? gen = await _runGenerate(result);
      if (mounted && gen != null && identical(_result, result)) {
        setState(() {
          _genResult = gen;
          _genProgress = '';
        });
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// 调生成服务：成功返回代码；失败返回 null，诚实原因写进生成卡片
  ///（仅当 [result] 仍是当前结果时，不污染新一次爬取的卡片）。
  /// 手动生成与自动进站共用同一服务与校验。
  Future<OneKeyCodeResult?> _runGenerate(ScrapeResult result) async {
    try {
      return await _pyService.generateFromScrape(
        scrapeUrl: result.url,
        html: result.html,
        pageTitle: result.pageTitle,
        linkUrls: result.links.map((ScrapeLink l) => l.url).toList(),
        onProgress: (String p) {
          if (mounted && identical(_result, result)) {
            setState(() => _genProgress = p);
          }
        },
      );
    } on OneKeyException catch (e) {
      if (mounted && identical(_result, result)) {
        setState(() {
          _genError = e.message;
          _genProgress = '';
        });
      }
      return null;
    } on Object catch (e) {
      if (mounted && identical(_result, result)) {
        setState(() {
          _genError = '生成失败：$e';
          _genProgress = '';
        });
      }
      return null;
    }
  }

  /// 导出 py 文件：鸿蒙走系统「另存为」对话框；其它平台先选目录保存，
  /// 取消选择时改走系统分享。用户取消不提示成功/失败。
  Future<void> _exportPy() async {
    final OneKeyCodeResult? gen = _genResult;
    if (gen == null) return;
    await _exportTextFile(
      fileName: gen.fileName,
      content: gen.code,
      savedLabel: '已保存 py 文件',
    );
  }

  /// 导出已生成的格式产物（书源 / 漫画规则 / TXT），与 py 同一落盘路径。
  Future<void> _exportFormatArtifact() async {
    final GeneratedFormatArtifact? artifact = _formatArtifact;
    if (artifact == null) return;
    await _exportTextFile(
      fileName: artifact.fileName,
      content: artifact.content,
      savedLabel: '已保存 ${artifact.fileName}',
    );
  }

  /// 文本文件导出：鸿蒙走系统「另存为」对话框；其它平台先选目录保存，
  /// 取消选择时改走系统分享。用户取消不提示成功/失败。
  Future<void> _exportTextFile({
    required String fileName,
    required String content,
    required String savedLabel,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      if (PlatformService.instance.isOHOS) {
        final String? saved = await FileExporter.saveTextFile(
          fileName: fileName,
          content: content,
        );
        if (saved == null) return;
        messenger.showSnackBar(SnackBar(content: Text(savedLabel)));
        return;
      }
      final String? dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null) {
        final File file = File(p.join(dir, fileName));
        await file.writeAsString(content);
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('已保存到：${file.path}')),
          );
        }
        return;
      }
      final Directory tmp = await getTemporaryDirectory();
      final File tmpFile = File(p.join(tmp.path, fileName));
      await tmpFile.writeAsString(content);
      await Share.shareXFiles(<XFile>[XFile(tmpFile.path)]);
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  /// 把已生成的 py 注册进站点列表（可选，默认不注册）。
  Future<void> _registerPy() async {
    final OneKeyCodeResult? gen = _genResult;
    if (gen == null || _registering || _registered) return;
    final OneKeyGenerateResult? res = await _registerGeneratedCode(gen);
    if (res == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.updated
              ? '已更新源：${res.config.name}'
              : '已注册进站点列表：${res.config.name}',
        ),
      ),
    );
  }

  /// 注册已生成的 py：成功返回注册结果（含源记录），失败报真原因
  /// 并返回 null。手动注册与自动进站共用同一校验与存储路径。
  Future<OneKeyGenerateResult?> _registerGeneratedCode(
    OneKeyCodeResult gen,
  ) async {
    setState(() => _registering = true);
    try {
      final OneKeyGenerateResult res = await _pyService.registerGenerated(
        repo: context.read<SourceRepository>(),
        generated: gen,
      );
      if (!mounted) return null;
      setState(() => _registered = true);
      return res;
    } on OneKeyException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return null;
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('注册失败：$e')),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  /// 各模式默认选中的生成格式：小说/文章默认 JSON 书源，漫画默认
  /// JSON 漫画规则，其余默认 py。
  ScrapeGenFormat _defaultFormatForMode(ScrapeMode mode) {
    switch (mode) {
      case ScrapeMode.novel:
      case ScrapeMode.article:
        return ScrapeGenFormat.bookJson;
      case ScrapeMode.comic:
        return ScrapeGenFormat.comicJson;
      case ScrapeMode.general:
      case ScrapeMode.video:
        return ScrapeGenFormat.py;
    }
  }

  /// 本次爬取数据的格式可用性（带缓存，避免每次 build 重解析 HTML）。
  List<FormatAvailability> _availabilities(ScrapeResult result) {
    if (_availCache != null &&
        identical(_availCacheResult, result) &&
        _availCacheMode == _mode) {
      return _availCache!;
    }
    final avail = planScrapeFormats(mode: _mode, result: result);
    _availCache = avail;
    _availCacheResult = result;
    _availCacheMode = _mode;
    return avail;
  }

  /// 当前有效的选中格式：选中格式不在本次数据可选列表里时
  ///（爬取后切换了模式），回落到列表首个格式。
  ScrapeGenFormat _effectiveFormat() {
    final ScrapeResult? result = _result;
    if (result == null) return _selectedFormat;
    final avail = _availabilities(result);
    if (avail.any((a) => a.format == _selectedFormat)) {
      return _selectedFormat;
    }
    return avail.first.format;
  }

  /// 按当前选中的格式生成：py 走现有的一键生成，其余走格式生成器。
  Future<void> _generateSelected() async {
    if (_effectiveFormat() == ScrapeGenFormat.py) {
      await _generatePy();
      return;
    }
    await _generateFormat();
  }

  /// 生成选中的非 py 格式：依据本次爬取数据推导规则，生成后用 App
  /// 自身解析器校验，校验不过报真原因、不产出假规则。
  Future<void> _generateFormat() async {
    final ScrapeResult? result = _result;
    if (result == null || _generating) return;
    final ScrapeGenFormat format = _effectiveFormat();
    setState(() {
      _generating = true;
      _genProgress = '正在生成${format.label}…';
      _genError = null;
      _genResult = null;
      _formatArtifact = null;
      _registered = false;
    });
    // 让出一个事件循环，使“生成中”状态先画出来。
    await Future<void>.delayed(Duration.zero);
    try {
      final artifact = generateScrapeFormat(
        format: format,
        mode: _mode,
        result: result,
        siteName: OneKeyPyService.sanitizeTitle(result.pageTitle),
      );
      if (mounted && identical(_result, result)) {
        setState(() {
          _formatArtifact = artifact;
          _genProgress = '';
        });
      }
    } on ScrapeFormatException catch (e) {
      if (mounted && identical(_result, result)) {
        setState(() {
          _genError = e.message;
          _genProgress = '';
        });
      }
    } on Object catch (e) {
      if (mounted && identical(_result, result)) {
        setState(() {
          _genError = '生成失败：$e';
          _genProgress = '';
        });
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// 把已生成的格式产物注册进对应的登记处，注册后打开对应分区的
  /// 浏览页（小说 / 漫画），复用现成的分区入口。
  Future<void> _registerFormatArtifact() async {
    final GeneratedFormatArtifact? artifact = _formatArtifact;
    if (artifact == null || _registering || _registered) return;
    setState(() => _registering = true);
    try {
      final SourceRepository repo = context.read<SourceRepository>();
      final PluginConfig config;
      switch (artifact.destination) {
        case FormatDestination.bookSources:
          config = await registerBookSourceText(
            repo: repo,
            text: artifact.content,
          );
          break;
        case FormatDestination.comicSources:
          config = await registerRuleJsonText(
            repo: repo,
            text: artifact.content,
          );
          break;
        case FormatDestination.siteList:
          return;
      }
      if (!mounted) return;
      setState(() => _registered = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已注册：${config.name}')),
      );
      _openRegisteredSource(config, artifact.destination);
    } on ScrapeFormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('注册失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  /// 打开已注册源的分区浏览页：书源进小说区，漫画规则进漫画区。
  void _openRegisteredSource(PluginConfig source, FormatDestination dest) {
    final Widget page;
    switch (dest) {
      case FormatDestination.bookSources:
        page = NovelOnlineListScreen(initialSource: source);
        break;
      case FormatDestination.comicSources:
        page = MangaOnlineListScreen(initialSource: source);
        break;
      case FormatDestination.siteList:
        return;
    }
    Navigator.of(context).push(AppPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.browseWebScrape)),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: Column(
              children: <Widget>[
                AppSegmentedTabs<ScrapeMode>(
                  selected: <ScrapeMode>{_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                  segments: <ButtonSegment<ScrapeMode>>[
                    ButtonSegment<ScrapeMode>(value: ScrapeMode.general, label: Text(l10n.scrapeModeGeneral)),
                    ButtonSegment<ScrapeMode>(value: ScrapeMode.novel, label: Text(l10n.scrapeModeNovel)),
                    ButtonSegment<ScrapeMode>(value: ScrapeMode.comic, label: Text(l10n.scrapeModeComic)),
                    ButtonSegment<ScrapeMode>(value: ScrapeMode.video, label: Text(l10n.scrapeModeVideo)),
                    ButtonSegment<ScrapeMode>(value: ScrapeMode.article, label: Text(l10n.scrapeModeArticle)),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceMd),
                AppUrlInputBar(
                  controller: _urlCtl,
                  hintText: l10n.scrapeUrlHint,
                  isLoading: _loading,
                  submitLabel: l10n.scrapeStart,
                  onSubmit: _scrape,
                ),
              ],
            ),
          ),
          Expanded(child: _buildResult(l10n, scheme)),
        ],
      ),
    );
  }

  Widget _buildResult(AppLocalizations l10n, ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AppErrorState(message: l10n.loadFailed, onRetry: () => _scrape(_urlCtl.text), retryLabel: l10n.retry);
    }
    final result = _result;
    if (result == null) {
      return AppEmptyState(icon: Icons.travel_explore_rounded, message: l10n.scrapeUrlHint);
    }
    if (result.isEmpty) {
      return AppEmptyState(icon: Icons.search_off_rounded, message: l10n.scrapeNoResults);
    }

    final title = result.pageTitle ?? l10n.scrapeResultTitle;

    return ListView(
      padding: context.pageInset(AppTokens.spaceLg),
      children: <Widget>[
        if (result.pageTitle != null)
          Text(result.pageTitle!, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppTokens.spaceMd),
        ..._buildGenerateCard(scheme),
        const SizedBox(height: AppTokens.spaceMd),
        if (_mode == ScrapeMode.general) ..._buildLinks(l10n),
        if (_mode == ScrapeMode.novel || _mode == ScrapeMode.article) ..._buildText(l10n, title, scheme),
        if (_mode == ScrapeMode.comic) ..._buildImages(l10n, title, scheme),
        if (_mode == ScrapeMode.video) ..._buildVideos(l10n, scheme),
      ],
    );
  }

  /// 一键生成区：位于爬取结果顶部，所有模式共用。用户先选格式再
  /// 生成；每个格式按本次爬取数据标明能不能生成，数据不够的写明
  /// 缺什么。生成后可导出文件，也可注册进对应分区的登记处。
  /// 视频 / 通用模式的自动进站点链路仍走 py，不受格式选择影响。
  List<Widget> _buildGenerateCard(ColorScheme scheme) {
    final OneKeyCodeResult? gen = _genResult;
    final GeneratedFormatArtifact? artifact = _formatArtifact;
    final ScrapeResult result = _result!;
    final List<FormatAvailability> avail = _availabilities(result);
    final ScrapeGenFormat effective = _effectiveFormat();
    final FormatAvailability selected = avail.firstWhere(
      (a) => a.format == effective,
      orElse: () => avail.first,
    );
    return <Widget>[
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '一键生成',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                '依据本次爬取的页面数据生成（站点地址、页面结构、标题与链接），不用重新输网址。先选格式，再点生成。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              Wrap(
                spacing: AppTokens.spaceSm,
                runSpacing: AppTokens.spaceSm,
                children: avail
                    .map(
                      (a) => ChoiceChip(
                        label: Text(
                          a.available
                              ? a.format.label
                              : '${a.format.label}（不可用）',
                        ),
                        selected: a.format == effective,
                        onSelected: (_) =>
                            setState(() => _selectedFormat = a.format),
                      ),
                    )
                    .toList(),
              ),
              if (!selected.available &&
                  selected.missingReason != null) ...<Widget>[
                const SizedBox(height: AppTokens.spaceMd),
                Container(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.info_outline_rounded),
                      const SizedBox(width: AppTokens.spaceSm),
                      Expanded(
                        child: Text(
                          '缺数据，无法生成${selected.format.label}：'
                          '${selected.missingReason}',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: AppTokens.spaceMd),
              FilledButton.icon(
                onPressed:
                    (_generating || !selected.available) ? null : _generateSelected,
                icon: const Icon(Icons.auto_fix_high_rounded),
                label: Text(
                  _generating ? '生成中…' : '生成${selected.format.label}',
                ),
              ),
              if (_genProgress.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppTokens.spaceMd),
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    Expanded(child: Text(_genProgress)),
                  ],
                ),
              ],
              if (_genError != null) ...<Widget>[
                const SizedBox(height: AppTokens.spaceMd),
                Container(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                  ),
                  child: Text(
                    _genError!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
              if (gen != null) ...<Widget>[
                const SizedBox(height: AppTokens.spaceMd),
                const Divider(),
                const SizedBox(height: AppTokens.spaceSm),
                Row(
                  children: <Widget>[
                    const Icon(Icons.check_circle_rounded, color: Colors.green),
                    const SizedBox(width: AppTokens.spaceSm),
                    Expanded(
                      child: Text(
                        '已生成：${gen.siteName}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Text('文件：${gen.fileName}'),
                Text('模板：${gen.templateId}（${gen.mode}）'),
                if (gen.api.isNotEmpty) Text('接口：${gen.api}'),
                Text('基址：${gen.base}'),
                const SizedBox(height: AppTokens.spaceMd),
                Wrap(
                  spacing: AppTokens.spaceSm,
                  runSpacing: AppTokens.spaceSm,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: _exportPy,
                      icon: const Icon(Icons.file_download_rounded),
                      label: const Text('导出 py 文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          (_registering || _registered) ? null : _registerPy,
                      icon: const Icon(Icons.add_rounded),
                      label: Text(
                        _registered
                            ? '已注册进站点列表'
                            : _registering
                                ? '注册中…'
                                : '注册进站点列表',
                      ),
                    ),
                  ],
                ),
                if (_registered) ...<Widget>[
                  const SizedBox(height: AppTokens.spaceSm),
                  const Text('已在站点列表里，可在源列表里启用、编辑、删除。'),
                ],
              ],
              if (artifact != null) ...<Widget>[
                const SizedBox(height: AppTokens.spaceMd),
                const Divider(),
                const SizedBox(height: AppTokens.spaceSm),
                Row(
                  children: <Widget>[
                    const Icon(Icons.check_circle_rounded, color: Colors.green),
                    const SizedBox(width: AppTokens.spaceSm),
                    Expanded(
                      child: Text(
                        '已生成：${artifact.format.label}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Text('文件：${artifact.fileName}'),
                ...artifact.metaLines.map((line) => Text(line)),
                const SizedBox(height: AppTokens.spaceMd),
                Wrap(
                  spacing: AppTokens.spaceSm,
                  runSpacing: AppTokens.spaceSm,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: _exportFormatArtifact,
                      icon: const Icon(Icons.file_download_rounded),
                      label: const Text('导出文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_registering || _registered)
                          ? null
                          : _registerFormatArtifact,
                      icon: const Icon(Icons.add_rounded),
                      label: Text(
                        _registered
                            ? '已注册'
                            : _registering
                                ? '注册中…'
                                : artifact.destination ==
                                        FormatDestination.bookSources
                                    ? '注册进书源列表'
                                    : '注册进漫画源列表',
                      ),
                    ),
                  ],
                ),
                if (_registered) ...<Widget>[
                  const SizedBox(height: AppTokens.spaceSm),
                  const Text('已在对应分区列表里，可在源列表里启用、编辑、删除。'),
                ],
              ],
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildLinks(AppLocalizations l10n) => <Widget>[
        Text(l10n.scrapeResultLinks, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        ..._result!.links.map((link) => ListTile(
              leading: const Icon(Icons.link_rounded),
              title: Text(link.text.isEmpty ? link.url : link.text, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(link.url, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.open_in_new_rounded),
                tooltip: l10n.openInBrowser,
                onPressed: () => _launch(link.url),
              ),
              onTap: () => _scrapeUrl(link.url),
            )),
      ];

  List<Widget> _buildText(AppLocalizations l10n, String title, ColorScheme scheme) => <Widget>[
        if (_result!.paragraphs.isNotEmpty)
          FilledButton.icon(
            onPressed: () => _openNovelText(title),
            icon: const Icon(Icons.menu_book_rounded),
            label: Text(l10n.scrapeOpenInReader),
          ),
        const SizedBox(height: AppTokens.spaceMd),
        if (_result!.imageUrls.isNotEmpty) ..._buildImages(l10n, title, scheme),
        const SizedBox(height: AppTokens.spaceMd),
        SelectableText(
          _result!.paragraphs.join('\n\n'),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ];

  List<Widget> _buildImages(AppLocalizations l10n, String title, ColorScheme scheme) => <Widget>[
        Text(l10n.scrapeResultImages, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        FilledButton.icon(
          onPressed: () => _openImages(title),
          icon: const Icon(Icons.visibility_rounded),
          label: Text(l10n.scrapeOpenInReader),
        ),
        const SizedBox(height: AppTokens.spaceMd),
        Wrap(
          spacing: AppTokens.spaceSm,
          runSpacing: AppTokens.spaceSm,
          children: _result!.imageUrls
              .take(12)
              .map((u) => InkWell(
                    onTap: () => _openImages(title),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                      child: Image.network(u, width: 96, height: 128, fit: BoxFit.cover),
                    ),
                  ))
              .toList(),
        ),
      ];

  List<Widget> _buildVideos(AppLocalizations l10n, ColorScheme scheme) => <Widget>[
        Text(l10n.scrapeResultVideos, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        if (_result!.videoUrls.isEmpty)
          Text(l10n.scrapeNoResults, style: Theme.of(context).textTheme.bodyMedium)
        else ...<Widget>[
          FilledButton.icon(
            onPressed: () => _openVideoInApp(_result!.videoUrls.first, l10n),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(l10n.scrapeOpenInPlayer),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          ..._result!.videoUrls.map((v) => ListTile(
                leading: const Icon(Icons.play_circle_rounded),
                title: Text(v.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _openVideoInApp(v, l10n),
              )),
        ],
      ];
}
