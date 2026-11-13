/// 下载来的 jar 文件存储：与 [PySourceStore] 平行，落点为
/// `<support>/jars/<slug>_<sha256 前 12 位>.jar`。
///
/// 文件名带内容哈希：同一 jar 地址更新内容后落成新文件，原生侧
/// `SpiderBridge` 按 jar 引用缓存 DexClassLoader，新引用必然触发新加载，
/// 不会拿到旧 jar 的类。源记录的 `spiderEngine.asset` 记
/// `file:<绝对路径>`，与原生侧 `resolveJarFile` 的 `file:` 约定一致。
///
/// 一个 jar 常被多个站点共用，删单个源时不删 jar 文件（与现有 py 文件
/// 的删除策略不同：py 文件按源 id 独占，jar 文件按内容共享）。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class JarSourceStore {
  JarSourceStore._();

  static const String _dirName = 'jars';

  static Future<Directory> _dir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 下载地址 + 内容 → 文件名（内容寻址，同一内容只存一份）。
  static String fileNameFor(String url, List<int> bytes) {
    final String digest = sha256.convert(bytes).toString().substring(0, 12);
    final Uri? uri = Uri.tryParse(url);
    final String last =
        uri == null || uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final String slug = '${uri?.host ?? ''}_$last'
        .replaceAll(RegExp(r'[^A-Za-z0-9_.\-]+'), '_')
        .replaceAll(RegExp(r'\.jar$', caseSensitive: false), '')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final String base = slug.length > 40 ? slug.substring(0, 40) : slug;
    return '${base.isEmpty ? 'jar' : base}_$digest.jar';
  }

  /// 保存下载到的 jar 字节，返回 `file:<绝对路径>` 形式的 jar 引用
  /// （直接写入 `spiderEngine.asset`）。同名文件已存在时不重复写。
  static Future<String> saveJar(String url, List<int> bytes) async {
    final dir = await _dir();
    final file = File('${dir.path}/${fileNameFor(url, bytes)}');
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return 'file:${file.path}';
  }
}
