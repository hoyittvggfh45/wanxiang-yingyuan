import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/services/source_library_subscription.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/features/sources/presentation/source_create_dialog.dart';
import 'package:wxyy/features/sources/presentation/source_edit_screen.dart';
import 'package:wxyy/features/sources/presentation/source_manager_screen.dart';
import 'package:wxyy/generated/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 仅含对话框的最小宿主：点按钮打开对话框，结果写入 [out]。
  Future<void> pumpDialogHost(
    WidgetTester tester, {
    required SourceType initialType,
    SourceType? lockedType,
    required List<PluginConfig?> out,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  final config = await showSourceCreateDialog(
                    context,
                    initialType: initialType,
                    lockedType: lockedType,
                  );
                  out.add(config);
                },
                child: const Text('打开新建对话框'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开新建对话框'));
    await tester.pumpAndSettle();
    expect(find.byType(SourceCreateDialog), findsOneWidget);
  }

  Future<void> fillAndCreate(
    WidgetTester tester, {
    required String name,
    required String url,
  }) async {
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-source-name')),
      name,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-source-url')),
      url,
    );
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();
  }

  group('SourceCreateDialog', () {
    testWidgets('填站名地址类型后创建，返回默认类型配置', (tester) async {
      final out = <PluginConfig?>[];
      await pumpDialogHost(
        tester,
        initialType: SourceType.novelSource,
        out: out,
      );
      await fillAndCreate(
        tester,
        name: '我的小说站',
        url: 'https://novel.example.com',
      );
      expect(find.byType(SourceCreateDialog), findsNothing);
      expect(out, hasLength(1));
      final config = out.single!;
      expect(config.name, '我的小说站');
      expect(config.type, SourceType.novelSource);
      expect(config.site.baseUrl, 'https://novel.example.com');
      expect(config.validate(), isEmpty);
    });

    testWidgets('类型选择正确落盘', (tester) async {
      final out = <PluginConfig?>[];
      await pumpDialogHost(
        tester,
        initialType: SourceType.novelSource,
        out: out,
      );
      await tester.tap(find.text('漫画'));
      await tester.pumpAndSettle();
      await fillAndCreate(
        tester,
        name: '漫画站',
        url: 'https://manga.example.com',
      );
      expect(out.single!.type, SourceType.mangaSource);
    });

    testWidgets('地址非法时报错且对话框不关闭、不返回配置', (tester) async {
      final out = <PluginConfig?>[];
      await pumpDialogHost(
        tester,
        initialType: SourceType.novelSource,
        out: out,
      );
      await fillAndCreate(tester, name: '站', url: 'example.com');
      expect(find.byType(SourceCreateDialog), findsOneWidget);
      expect(find.textContaining('合法网址'), findsOneWidget);
      expect(out, isEmpty);
    });

    testWidgets('站名为空时报错且不返回配置', (tester) async {
      final out = <PluginConfig?>[];
      await pumpDialogHost(
        tester,
        initialType: SourceType.novelSource,
        out: out,
      );
      await fillAndCreate(tester, name: '', url: 'https://example.com');
      expect(find.byType(SourceCreateDialog), findsOneWidget);
      expect(find.text('请填写站名'), findsOneWidget);
      expect(out, isEmpty);
    });

    testWidgets('锁定类型时不显示类型选择，创建即锁定类型', (tester) async {
      final out = <PluginConfig?>[];
      await pumpDialogHost(
        tester,
        initialType: SourceType.novelSource,
        lockedType: SourceType.audioSource,
        out: out,
      );
      expect(find.byType(SegmentedButton<SourceType>), findsNothing);
      expect(find.text('听书'), findsOneWidget);
      await fillAndCreate(
        tester,
        name: '听书站',
        url: 'https://audio.example.com',
      );
      expect(out.single!.type, SourceType.audioSource);
    });

    testWidgets('取消返回 null', (tester) async {
      final out = <PluginConfig?>[];
      await pumpDialogHost(
        tester,
        initialType: SourceType.novelSource,
        out: out,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(out, <PluginConfig?>[null]);
    });
  });

  group('SourceManagerScreen 新建入口', () {
    testWidgets('源列表 Tab 有新建空白源入口，建好后注册进仓并打开编辑页',
        (tester) async {
      final repo = SourceRepository(<PluginConfig>[]);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SourceRepository>.value(value: repo),
            ChangeNotifierProvider<SourceLibrarySubscription>.value(
              value: SourceLibrarySubscription(),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            supportedLocales: <Locale>[Locale('zh'), Locale('en')],
            localizationsDelegates: <LocalizationsDelegate<dynamic>>[
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: Scaffold(
              body: SourceManagerScreen(embedded: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 入口与原有「添加源」（跳网络导入）同时存在、互不冲突。
      expect(find.text('新建空白源'), findsOneWidget);
      expect(find.text('添加源'), findsOneWidget);

      await tester.tap(find.text('新建空白源'));
      await tester.pumpAndSettle();
      expect(find.byType(SourceCreateDialog), findsOneWidget);

      await fillAndCreate(
        tester,
        name: '入口新建站',
        url: 'https://entry.example.com',
      );

      // 注册进仓，且编辑页已打开（可继续改全部字段）。
      expect(repo.all, hasLength(1));
      expect(repo.all.single.name, '入口新建站');
      expect(repo.all.single.type, SourceType.novelSource);
      expect(find.byType(SourceEditScreen), findsOneWidget);
    });
  });
}
