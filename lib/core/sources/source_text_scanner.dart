/// 导入文本的统一分派：本地文件 / 网络拉取 / 源库条目共用同一套识别顺序，
/// 保证源管理页、源管理面板、网络导入、源库四处行为一致。
///
/// 识别顺序：
/// 1. `.py` 文件（按文件名后缀）：py 校验，校验通过进待确认项，失败报校验结论；
/// 2. TVBox / 猫源配置：走 [resolveTvboxConfigText]（含 jar / py 下载）；
/// 3. 原有混合格式：[SourceRepository.parseMixedSources]
///    （PluginConfig / JSON 数组 / 通用书源 / XML / NDJSON）；
/// 4. 兜底：扩展名缺失（如 SAF 文档名无后缀）且文本含 `class Spider` 时，
///    按 py 再试一次，校验结论如实返回。
///
/// 年龄门与类型过滤不在此做，由各调用方按现有逻辑处理（本层只返回候选）。
library;

import '../models/plugin_config.dart';
import '../services/source_repository.dart';
import 'pending_py_import.dart';
import 'tvbox_config_parser.dart';
import 'tvbox_importer.dart';

/// 一份导入文本的扫描结果。
class ScannedSourceText {
  const ScannedSourceText({
    this.configs = const <PluginConfig>[],
    this.pendingPy = const <PendingPyImport>[],
    this.errors = const <String>[],
  });

  /// 可直接注册的源配置。
  final List<PluginConfig> configs;

  /// 待确认的 py 导入项（确认时走 `PyImporter.importCode` 注册）。
  final List<PendingPyImport> pendingPy;

  /// 逐条错误 / 未导入说明（失败站点原因、不支持的顶层段）。
  final List<String> errors;

  /// 是否完全没有产出（无配置、无待确认 py、无错误说明）——调用方按
  /// 「无法识别」处理。
  bool get isEmpty => configs.isEmpty && pendingPy.isEmpty && errors.isEmpty;
}

/// 扫描一份导入文本，返回候选源、待确认 py 与错误说明。
///
/// [fileName] 用于判定 `.py` 后缀（网络导入时传拉取地址，同样按后缀判定，
/// 地址里的查询串/片段会被去掉）；[baseUri] 为文本来源地址，用于解析
/// TVBox 配置内的相对 jar / py 地址，本地文件导入时不传。
Future<ScannedSourceText> scanSourceText({
  required String fileName,
  required String text,
  String? baseUri,
}) async {
  final String baseName = fileName.split('/').last.split('\\').last;
  final String namePart = baseName.split('?').first.split('#').first;
  final int dot = namePart.lastIndexOf('.');
  final String ext = dot > 0 ? namePart.substring(dot + 1).toLowerCase() : '';

  // 1. .py 文件：校验→待确认，失败报校验结论。
  if (ext == 'py') {
    final PendingPyImport? pending =
        PendingPyImport.tryCreate(fileName: namePart, code: text);
    if (pending != null) {
      return ScannedSourceText(pendingPy: <PendingPyImport>[pending]);
    }
    return ScannedSourceText(
      errors: <String>[PendingPyImport.failureReasonOf(text)],
    );
  }

  // 2. TVBox / 猫源配置。
  final TvboxImportOutcome tvbox =
      await resolveTvboxConfigText(text, baseUri: baseUri);
  if (tvbox.isRecognized) {
    return ScannedSourceText(
      configs: tvbox.configs,
      pendingPy: tvbox.pendingPy,
      errors: <String>[
        for (final TvboxSiteFailure f in tvbox.failures)
          '${f.name.isNotEmpty ? f.name : f.key}：${f.reason}',
        for (final String s in tvbox.unsupportedSections) '未导入：$s',
      ],
    );
  }

  // 3. 原有混合格式。
  final List<PluginConfig> configs = SourceRepository.parseMixedSources(text);
  if (configs.isNotEmpty) {
    return ScannedSourceText(configs: configs);
  }

  // 4. 兜底：扩展名缺失且文本含 Spider 类时按 py 再试一次。
  if (ext.isEmpty && text.contains('class Spider')) {
    final PendingPyImport? pending = PendingPyImport.tryCreate(
      fileName: '$namePart.py',
      code: text,
    );
    if (pending != null) {
      return ScannedSourceText(pendingPy: <PendingPyImport>[pending]);
    }
    return ScannedSourceText(
      errors: <String>[PendingPyImport.failureReasonOf(text)],
    );
  }

  return const ScannedSourceText();
}
