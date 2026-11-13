/// py 蜘蛛源码的待确认导入项：校验通过的源码先放进导入预览，
/// 用户勾选确认后才由 `PyImporter.importCode` 落盘注册。
///
/// 校验口径与 `py_import_sheet.dart` 的 `PyImporter` 完全一致
/// （同一份 [validatePySource] + 同一条 JS 蜘蛛提示），这里只做
/// 预览期的判定，不另写一套校验；最终注册仍走 `PyImporter.importCode`，
/// 由它再次校验、推导最终源 id 并写入源仓库。
library;

import '../models/plugin_config.dart';
import '../spider/py_spider_validator.dart';

/// 一份待确认的 py 导入：预览显示用 [previewConfig]，确认注册用
/// [fileName] + [code]（经 `PyImporter.importCode`）。
class PendingPyImport {
  const PendingPyImport({
    required this.fileName,
    required this.code,
    required this.previewConfig,
  });

  /// 用于推导源 id 的文件名（如 `missav.py`，TVBox 站点则为 `<key>.py`）。
  final String fileName;

  /// py 蜘蛛源码全文。
  final String code;

  /// 仅供预览展示的源配置（名称/类型/备注与最终注册结果一致；
  /// 其 id 只是预览占位，最终 id 由 `PyImporter.importCode` 在确认时推导）。
  final PluginConfig previewConfig;

  /// 校验 [code]，通过返回待确认项，不通过返回 null
  /// （失败原因用 [failureReasonOf] 取，与 `PyImporter` 的文案一致）。
  static PendingPyImport? tryCreate({
    required String fileName,
    required String code,
  }) {
    final PyValidation validation = validatePySource(code);
    if (!validation.ok) return null;
    final String stem = _previewIdFromFileName(fileName);
    return PendingPyImport(
      fileName: fileName,
      code: code,
      previewConfig: PluginConfig(
        id: stem,
        name: validation.displayName ?? fileName,
        type: SourceType.animeSource,
        site: const SiteConfig(domain: '', baseUrl: ''),
        parser: const ParserConfig(type: 'py'),
        spiderEngine: SpiderEngineConfig(kind: 'py', sourceRef: 'file:$stem'),
        note: validation.remark,
        version: 1,
        enabled: true,
      ),
    );
  }

  /// 校验失败的原因文本（校验通过时返回空字符串）。
  ///
  /// 文案与 `PyImporter.importCode` 的失败原因逐字一致（含 JS 蜘蛛提示），
  /// 预览里的错误项直接展示它，不静默吞错。
  static String failureReasonOf(String code) {
    final PyValidation validation = validatePySource(code);
    if (validation.ok) return '';
    String reason = validation.failureReason;
    if (looksLikeJsSpider(code)) {
      reason = '$reason（看起来像 JS 蜘蛛脚本，不是 Python 蜘蛛）';
    }
    return reason;
  }

  /// 由文件名推导预览 id（仅预览展示用，最终 id 由 `PyImporter` 推导）。
  static String _previewIdFromFileName(String fileName) {
    final String stem = fileName.split('/').last.split('\\').last;
    final String base = stem.toLowerCase().replaceAll(RegExp(r'\.py$'), '');
    final String cleaned = base
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'py_source' : cleaned;
  }
}
