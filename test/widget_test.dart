import 'package:material_ui/material_ui.dart';
import 'package:wxyy/generated/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/download/download_file_system.dart';
import 'package:wxyy/core/download/download_manager.dart';
import 'package:wxyy/core/download/download_storage.dart';
import 'package:wxyy/core/favorites/favorites_manager.dart';
import 'package:wxyy/core/history/history_manager.dart';
import 'package:wxyy/core/local/local_content_manager.dart';
import 'package:wxyy/core/locale/locale_controller.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/resolver/resolver_registry.dart';
import 'package:wxyy/core/rss/rss_manager.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/theme/theme_controller.dart';
import 'package:wxyy/core/widgets/app_nav_bar.dart';
import 'package:wxyy/features/home/presentation/home_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('HomeScreen renders bottom nav and browse page',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final registry = ResolverRegistry.instance;
    final mediaService = MediaApiService(registry);
    final sourceRepo = SourceRepository(<PluginConfig>[]);
    final fs = InMemoryFileSystem();
    final storage = DownloadStorage();
    final downloadManager = DownloadManager(
      storage: storage,
      fs: fs,
      service: mediaService,
      sourceRepo: sourceRepo,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>(
            create: (_) => ThemeController(),
          ),
          ChangeNotifierProvider<LocaleController>(
            create: (_) => LocaleController(),
          ),
          ChangeNotifierProvider<SourceRepository>.value(value: sourceRepo),
          Provider<ResolverRegistry>.value(value: registry),
          Provider<MediaApiService>.value(value: mediaService),
          ChangeNotifierProvider<DownloadManager>.value(value: downloadManager),
          ChangeNotifierProvider<FavoritesManager>(
            create: (_) => FavoritesManager(),
          ),
          ChangeNotifierProvider<HistoryManager>(
            create: (_) => HistoryManager(),
          ),
          ChangeNotifierProvider<LocalContentManager>(
            create: (_) => LocalContentManager(),
          ),
          ChangeNotifierProvider<RssManager>(
            create: (_) => RssManager(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(useMaterial3: true),
          home: const HomeScreen(),
        ),
      ),
    );

    // 不用 pumpAndSettle：HomeScreen 把 7 个 Tab 页一次性建在 Stack 里
    // （Offstage 藏起来的页动画照样跑），其中直播页在加载清单时显示
    // 不定式 CircularProgressIndicator；其 rootBundle 资源加载在
    // testWidgets 的 FakeAsync 环境里不回落（真实异步下实测能加载，
    // 属测试环境差异、非界面 bug），pumpAndSettle 永远等不到空闲。
    // 逐页实测只有直播页不回落，其余 6 页都回落。本用例只断言底导
    // 与浏览页，抽水到入场动画跑完即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // AppNavBar 替代裸 NavigationBar，移动端用自定义控件渲染。
    expect(find.byType(AppNavBar), findsOneWidget);
    expect(find.text('浏览'), findsWidgets);
  });
}
