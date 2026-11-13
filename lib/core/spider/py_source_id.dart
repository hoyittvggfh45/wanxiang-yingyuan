/// py 蜘蛛源 id 推导：由文件名推导源 id。
///
/// 导入、生成、去重查找共用同一推导，勿各自另写，避免同一份 py
/// 算出不同 id（去重查不到）或不同 py 撞上同一 id。
library;

/// 由文件名推导源 id：去后缀、小写、仅留字母数字下划线。
String pySourceIdFromFileName(String fileName) {
  final String stem = fileName.split('/').last.split('\\').last;
  final String base = stem.toLowerCase().replaceAll(RegExp(r'\.py$'), '');
  final String cleaned = base
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return cleaned.isEmpty ? 'py_source' : cleaned;
}
