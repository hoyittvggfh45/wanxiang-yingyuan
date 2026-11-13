/// 备份导入 / 导出：勾选实时刷新、全选切换、选择器异常降级。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/services/backup_archive.dart';
import 'package:wxyy/core/widgets/backup_category_selector.dart';
import 'package:wxyy/features/settings/presentation/settings_import_export_screen.dart';
import 'package:wxyy/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      // material_ui 自带一套 MaterialLocalizations：生成代码的
      // AppLocalizations.localizationsDelegates 用的是 flutter 官方代理，
      // material_ui 的 AppBar/CheckboxListTile 认不到，会报
      // No MaterialLocalizations found。按 widget_test.dart 的做法，
      // 用 material_ui 的 GlobalMaterialLocalizations.delegates。
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: Scaffold(body: child),
    );

/// 模拟用户取消选择：返回 null，供测试收尾时恢复一个无害的平台实现。
class _NullFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      null;
}

/// 模拟鸿蒙 file_picker 取消选择时抛出的原生异常。
class _ThrowingFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    throw PlatformException(
      code: 'unknown_activity',
      message: 'Unknown activity error, please fill an issue.',
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('全选按钮在全选时显示「全不选」并可清空', (WidgetTester tester) async {
    Set<BackupCategory> selected =
        Set<BackupCategory>.from(kSelectableBackupCategories);

    await tester.pumpWidget(_wrap(
      StatefulBuilder(
        builder: (context, setState) => BackupCategorySelector(
          selected: selected,
          onChanged: (next) => setState(() => selected = next),
        ),
      ),
    ));

    expect(find.text('全不选'), findsOneWidget);
    expect(find.text('全选'), findsNothing);

    await tester.tap(find.text('全不选'));
    await tester.pump();
    expect(selected, isEmpty);
    expect(find.text('全选'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(selected.length, kSelectableBackupCategories.length);
    expect(find.text('全不选'), findsOneWidget);
  });

  testWidgets('导出弹层勾选实时刷新，全选状态随之切换', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const SettingsImportExportScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();

    // 初始全选：提示「全不选」。
    expect(find.text('全不选'), findsOneWidget);

    final sourceTile = find.widgetWithText(CheckboxListTile, '源与订阅');
    expect(tester.widget<CheckboxListTile>(sourceTile).value, isTrue);

    // 取消一类后立即显示为未勾选，且按钮切回「全选」。
    await tester.tap(sourceTile);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(sourceTile).value, isFalse);
    expect(find.text('全选'), findsOneWidget);

    // 点「全选」恢复全选，按钮切回「全不选」。
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(sourceTile).value, isTrue);
    expect(find.text('全不选'), findsOneWidget);
  });

  testWidgets('导入选择器抛原生异常时提示失败，不产生未捕获异常', (WidgetTester tester) async {
    // 测试环境未注册 file_picker 平台实现，读 FilePicker.platform 会抛
    // LateInitializationError（_instance 是 late 静态字段）。只写不读，
    // 收尾恢复为返回 null 的无害实现。
    FilePicker.platform = _ThrowingFilePicker();
    addTearDown(() => FilePicker.platform = _NullFilePicker());

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const SettingsImportExportScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.file_open_rounded));
    // 提示条 4 秒后自动消失：pumpAndSettle 会把假时钟推过消失点，
    // 再断言就找不着文本。只抽水到提示条进场完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('导入失败'), findsOneWidget);
  });
}
