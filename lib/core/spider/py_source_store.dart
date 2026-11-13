/// py 蜘蛛源码存储：导入的 py 存在应用支持目录，内置的 py 读资源包。
///
/// 落点：`<support>/py_sources/<源 id>.py`。源记录的 `spiderEngine.sourceRef`
/// 标记来源：`asset:<资源路径>`（内置）或 `file:<源 id>`（导入/生成）。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/plugin_config.dart';

class PySourceStore {
  PySourceStore._();

  static const String _dirName = 'py_sources';

  static Future<Directory> _dir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 源 id → 安全文件名（仅保留字母数字与 `_-.`，其余转下划线）。
  static String fileNameFor(String sourceId) {
    final safe = sourceId.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
    return '$safe.py';
  }

  /// 保存一份导入/生成的 py 源码，返回 `file:<源 id>` 形式的 sourceRef。
  static Future<String> saveSource(String sourceId, String code) async {
    final dir = await _dir();
    final file = File('${dir.path}/${fileNameFor(sourceId)}');
    await file.writeAsString(code, flush: true);
    return 'file:$sourceId';
  }

  /// 读取导入的 py 源码（不存在返回 null）。
  static Future<String?> readImported(String sourceId) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/${fileNameFor(sourceId)}');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 删除导入的 py 源码文件（源删除时调用，失败静默）。
  static Future<void> deleteSource(String sourceId) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/${fileNameFor(sourceId)}');
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 静默：残留文件不影响源删除本身。
    }
  }

  /// 按源记录的 sourceRef 取源码：内置走资源包，导入走文件。
  ///
  /// 找不到返回 null（调用方报诚实错误，不编假源码）。
  static Future<String?> readForSource(PluginConfig source) async {
    final engine = source.spiderEngine;
    final ref = engine?.sourceRef ?? '';
    if (ref.startsWith('asset:')) {
      try {
        return await rootBundle.loadString(ref.substring('asset:'.length));
      } catch (_) {
        return null;
      }
    }
    if (ref.startsWith('file:')) {
      return readImported(ref.substring('file:'.length));
    }
    final asset = engine?.asset;
    if (asset != null && asset.isNotEmpty) {
      try {
        return await rootBundle.loadString(asset);
      } catch (_) {
        return null;
      }
    }
    return readImported(source.id);
  }
}
