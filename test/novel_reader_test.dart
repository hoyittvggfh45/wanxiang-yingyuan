import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:wxyy/generated/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:wxyy/core/comic/models/reader_preferences.dart'
    show InMemoryBackend;
import 'package:wxyy/core/favorites/favorites_manager.dart';
import 'package:wxyy/core/models/episode.dart';
import 'package:wxyy/core/models/novel_block.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/resolver/resolver_registry.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/features/novel/presentation/novel_reader_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 小说阅读器测试：注入 [FakeNovelMediaApiService] 提供固定段落列表，
/// 绕过 widget 测试环境下的 HttpClient 桩。
class FakeNovelMediaApiService extends MediaApiService {
  FakeNovelMediaApiService() : super(ResolverRegistry.instance);

  @override
  Future<List<NovelBlock>> fetchNovelContent(
    PluginConfig source, {
    required String novelId,
    required String chapterUrl,
    String? renderedHtml,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return const <NovelBlock>[
      NovelTextBlock('这是第一段文字，用于测试小说阅读器的文本分页功能。'),
      NovelTextBlock('第二段内容继续展开，描述着主角在异世界的冒险经历。'),
      NovelTextBlock('第三段描写了一场激烈的战斗场景，剑光闪烁，魔法飞舞。'),
      NovelTextBlock('第四段转入平静的日常，主角与伙伴们在酒馆中休息。'),
      NovelTextBlock('第五段是本章的高潮，主角终于面对了最终的敌人。'),
      NovelTextBlock('最后一段为结尾，留下悬念，引向下一章的故事发展。'),
    ];
  }
}

void main() {
  setUpAll(() async {
    // NovelNoteManager / NovelBookmarkManager 依赖 Hive box，测试前需初始化。
    // 各文件独占一个临时目录：两小说阅读器测试曾共用系统临时目录，
    // 同跑时 Hive 文件锁冲突（errno 11）导致 setUpAll 失败。
    final hiveDir =
        await Directory.systemTemp.createTemp('novel_reader_test_hive');
    Hive.init(hiveDir.path);
    // 预先打开 box，使 NovelNoteManager.init() 走 isBoxOpen 快路径同步返回，
    // 避免 Hive.openBox() 在 _init() 中创建的异步计时器干扰 pumpAndSettle。
    await Hive.openBox('novel_notes');
    await Hive.openBox('novel_bookmarks');
    // 预下载缓存 box：同样预打开，避免阅读器 _loadChapter 里 Hive.openBox
    // 的后台任务阻塞 pumpAndSettle（读缓存走 isBoxOpen 快路径返回 null）。
    await Hive.openBox('novel_pre_downloads');
  });

  // 无 tearDownAll：Hive.deleteFromDisk() 在此会永久挂起——阅读器在
  // FakeAsync 内向 Hive 排队了写操作（真实 IO 永不完成），deleteFromDisk
  // 要等写队列排空。box 落在系统临时目录，随进程退出丢弃即可。

  testWidgets('reader renders content and toggles UI', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'novel_prefs_n1':
          '{"pageAnimation":"slide","fontSize":18.0,"lineHeight":1.8,"margin":24.0,"paragraphSpacing":16.0,"bgPresetIndex":2}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'nsrc1',
      'name': 'NS',
      'type': 'novelSource',
      'responseType': 'html',
      'site': {
        'domain': 'https://example.com',
        'baseUrl': 'https://example.com',
      },
      'parser': {'type': 'builtin'},
      'routes': {
        'toc': '/book/{id}/toc',
        'content': '/book/{id}/{chapter}',
      },
      'selectors': {
        'chapters': 'li.chapter',
        'content': '#content',
      },
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeNovelMediaApiService();
    final favorites = FavoritesManager(backend: InMemoryBackend());
    await favorites.init();
    const chapters = <Episode>[
      Episode(id: 'ch1', title: '第1章 开端', url: '/ch1'),
      Episode(id: 'ch2', title: '第2章 冒险', url: '/ch2'),
    ];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<MediaApiService>.value(value: service),
          ChangeNotifierProvider<SourceRepository>.value(value: repo),
          ChangeNotifierProvider<FavoritesManager>.value(value: favorites),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          supportedLocales: <Locale>[Locale('zh'), Locale('en')],
          localizationsDelegates: <LocalizationsDelegate<dynamic>>[
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: NovelReaderScreen(
            novelId: 'n1',
            title: '测试小说',
            sourceId: 'nsrc1',
            chapters: chapters,
          ),
        ),
      ),
    );

    // 等待异步加载完成。有限步进：阅读器 initState 起了 1 分钟周期的
    // 时钟定时器（Timer.periodic），pumpAndSettle 永远等不到静止。
    // 加载链是多段顺序等待，抽水直到正文出现（有上限，不会死等）。
    for (var i = 0;
        i < 50 && find.textContaining('第一段文字').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 验证小说内容已加载（页面中应包含段落文字）。
    expect(find.textContaining('第一段文字'), findsOneWidget);

    // 边距回归（漂移修复）：正文首行左边缘必须精确等于设定 margin=24，
    // 不得因 SingleChildScrollView 收缩包裹 + Column 居中而随内容宽度漂移。
    expect(tester.getTopLeft(find.textContaining('第一段文字')).dx, 24.0);

    // 正文滚动区必须占满视口宽度（800），验证不再随内容收缩包裹。
    expect(tester.getSize(find.byType(SingleChildScrollView)).width, 800.0);

    // 点击中心切换阅读器控件显隐（500ms 让显隐动画跑完）。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

    // 再次点击中心收起控件。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
  });
}
