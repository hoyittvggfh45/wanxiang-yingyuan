/// py 蜘蛛导入：选择 .py 文件 / 批量扫描文件夹 / 粘贴源码。
///
/// 既定做法：导入时校验 `class Spider` 与核心方法，校验结果写进源备注；
/// 形态不明的只报原因、不注册坏源；导进来的 py 自动注册进站点列表，
/// 与 JSON 源同列展示、可启用停用删除；同名（同 id）更新不重复建站。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/spider/py_source_id.dart';
import '../../../core/spider/py_source_store.dart';
import '../../../core/spider/py_spider_validator.dart';

/// 单条导入结果。
class PyImportOutcome {
  const PyImportOutcome({
    required this.fileName,
    required this.success,
    this.sourceId,
    this.updated,
    this.reason,
  });

  final String fileName;
  final bool success;
  final String? sourceId;
  final bool? updated;
  final String? reason;
}

/// py 导入逻辑（UI 无关，可单测校验部分逻辑）。
class PyImporter {
  /// 由文件名推导源 id（与生成、去重查找同一推导，见 [pySourceIdFromFileName]）。
  static String idFromFileName(String fileName) =>
      pySourceIdFromFileName(fileName);

  /// 导入一份 py 源码：校验 → 落盘 → 注册/更新。
  static Future<PyImportOutcome> importCode({
    required SourceRepository repo,
    required String fileName,
    required String code,
  }) async {
    final PyValidation validation = validatePySource(code);
    if (!validation.ok) {
      String reason = validation.failureReason;
      if (looksLikeJsSpider(code)) {
        reason = '$reason（看起来像 JS 蜘蛛脚本，不是 Python 蜘蛛）';
      }
      return PyImportOutcome(
        fileName: fileName,
        success: false,
        reason: reason,
      );
    }
    String id = idFromFileName(fileName);
    final PluginConfig? clash = repo.getById(id);
    if (clash != null && !clash.isPySource) {
      id = '${id}_py';
    }
    final String name = validation.displayName ?? fileName;
    final bool updated = repo.getById(id) != null;
    await PySourceStore.saveSource(id, code);
    final PluginConfig config = PluginConfig(
      id: id,
      name: name,
      type: SourceType.animeSource,
      site: const SiteConfig(domain: '', baseUrl: ''),
      parser: const ParserConfig(type: 'py'),
      spiderEngine: SpiderEngineConfig(kind: 'py', sourceRef: 'file:$id'),
      note: validation.remark,
      version: 1,
      enabled: true,
    );
    if (updated) {
      repo.replaceSource(config);
    } else {
      repo.addSource(config);
    }
    return PyImportOutcome(
      fileName: fileName,
      success: true,
      sourceId: id,
      updated: updated,
    );
  }
}

/// 打开 py 导入面板（底部动作表）。
Future<void> showPyImportSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.file_open_rounded),
            title: const Text('选择 .py 文件'),
            subtitle: const Text('校验通过后注册进站点列表'),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_pickPyFile(context));
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('批量扫描文件夹'),
            subtitle: const Text('扫描文件夹里全部 .py 批量注册'),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_scanPyFolder(context));
            },
          ),
          ListTile(
            leading: const Icon(Icons.content_paste_rounded),
            title: const Text('粘贴源码'),
            subtitle: const Text('粘贴 py 源码全文导入'),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_pastePyCode(context));
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _pickPyFile(BuildContext context) async {
  final FilePickerResult? picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: <String>['py'],
    withData: true,
  );
  if (picked == null || picked.files.isEmpty || !context.mounted) return;
  final PlatformFile file = picked.files.first;
  final List<int>? bytes = file.bytes;
  if (bytes == null) {
    _showMessage(context, '读取文件失败：${file.name}');
    return;
  }
  final SourceRepository repo = context.read<SourceRepository>();
  final PyImportOutcome outcome = await PyImporter.importCode(
    repo: repo,
    fileName: file.name,
    code: utf8.decode(bytes, allowMalformed: true),
  );
  if (!context.mounted) return;
  _showOutcome(context, outcome);
}

Future<void> _scanPyFolder(BuildContext context) async {
  final String? dirPath = await FilePicker.platform.getDirectoryPath();
  if (dirPath == null || dirPath.isEmpty || !context.mounted) return;
  final Directory dir = Directory(dirPath);
  if (!await dir.exists()) {
    _showMessage(context, '文件夹不存在：$dirPath');
    return;
  }
  final List<File> pyFiles = <File>[];
  await for (final FileSystemEntity e in dir.list(recursive: true)) {
    if (e is File && e.path.toLowerCase().endsWith('.py')) {
      pyFiles.add(e);
      if (pyFiles.length >= 200) break;
    }
  }
  if (pyFiles.isEmpty) {
    if (context.mounted) _showMessage(context, '文件夹里没有 .py 文件');
    return;
  }
  if (!context.mounted) return;
  final SourceRepository repo = context.read<SourceRepository>();
  final List<PyImportOutcome> outcomes = <PyImportOutcome>[];
  for (final File f in pyFiles) {
    try {
      final String code = await f.readAsString();
      outcomes.add(
        await PyImporter.importCode(
          repo: repo,
          fileName: f.path.split(Platform.pathSeparator).last,
          code: code,
        ),
      );
    } on Object catch (e) {
      outcomes.add(
        PyImportOutcome(
          fileName: f.path.split(Platform.pathSeparator).last,
          success: false,
          reason: '读取失败：$e',
        ),
      );
    }
  }
  if (!context.mounted) return;
  final int okCount = outcomes.where((PyImportOutcome o) => o.success).length;
  final int failCount = outcomes.length - okCount;
  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text('批量导入完成：成功 $okCount 个，失败 $failCount 个'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final PyImportOutcome o in outcomes)
              ListTile(
                dense: true,
                leading: Icon(
                  o.success
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  color: o.success ? Colors.green : Colors.red,
                ),
                title: Text(o.fileName),
                subtitle: Text(
                  o.success
                      ? (o.updated == true
                            ? '已更新：${o.sourceId}'
                            : '已注册：${o.sourceId}')
                      : (o.reason ?? '失败'),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

Future<void> _pastePyCode(BuildContext context) async {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController codeController = TextEditingController();
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('粘贴 py 源码'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '文件名（用于生成源 id，如 missav.py）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: '粘贴 py 蜘蛛源码全文',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('导入'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final String fileName = nameController.text.trim().isEmpty
      ? 'pasted.py'
      : nameController.text.trim();
  final String code = codeController.text;
  if (code.trim().isEmpty) {
    _showMessage(context, '源码为空，未导入');
    return;
  }
  final SourceRepository repo = context.read<SourceRepository>();
  final PyImportOutcome outcome = await PyImporter.importCode(
    repo: repo,
    fileName: fileName,
    code: code,
  );
  if (!context.mounted) return;
  _showOutcome(context, outcome);
}

void _showOutcome(BuildContext context, PyImportOutcome outcome) {
  if (outcome.success) {
    _showMessage(
      context,
      outcome.updated == true
          ? '已更新源：${outcome.sourceId}'
          : '已注册源：${outcome.sourceId}',
    );
  } else {
    _showMessage(context, '导入失败（${outcome.fileName}）：${outcome.reason}');
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
