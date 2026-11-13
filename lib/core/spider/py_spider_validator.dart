/// py 蜘蛛源码校验：判定 `class Spider` 与 TVBox 全协议方法是否齐全。
///
/// 结构参考火蚁TV `py_spider_validator.dart`：8 个核心方法 + 6 个可补齐
/// 方法；无 Spider 类直接不通过；缺核心方法但有 `playerContent` 时判为
/// 仅播放模式（`playOnly`），由引擎侧补齐缺失方法后仍可注册。
library;

/// 核心方法：缺失即无法完整担任源（仅播放模式除外）。
const List<String> pyCoreMethods = <String>[
  'getName',
  'init',
  'homeContent',
  'homeVideoContent',
  'categoryContent',
  'detailContent',
  'searchContent',
  'playerContent',
];

/// 可补齐方法：缺失时引擎以默认实现补齐，不影响注册。
const List<String> pyDefaultedMethods = <String>[
  'getDependence',
  'destroy',
  'localProxy',
  'isVideoFormat',
  'manualVideoCheck',
  'action',
];

/// 校验结果。
class PyValidation {
  const PyValidation({
    required this.hasSpider,
    required this.present,
    required this.missingCore,
    required this.missingDefaulted,
    required this.playOnly,
    this.displayName,
  });

  /// 是否含 `class Spider`。
  final bool hasSpider;

  /// 检测到的全部方法名。
  final Set<String> present;

  /// 缺失的核心方法。
  final List<String> missingCore;

  /// 缺失的可补齐方法。
  final List<String> missingDefaulted;

  /// 仅播放模式：缺核心方法但有 `playerContent`。
  final bool playOnly;

  /// 从 `getName` 返回字面量中抠出的显示名（抠不到为 null）。
  final String? displayName;

  /// 是否可注册（完整模式或仅播放模式）。
  bool get ok => hasSpider && (missingCore.isEmpty || playOnly);

  /// 写进源备注的校验结论（中文，一行）。
  String get remark {
    if (!hasSpider) return '校验不通过：未找到 class Spider';
    if (missingCore.isEmpty) {
      return '校验通过：核心方法 ${pyCoreMethods.length}/${pyCoreMethods.length}'
          '${missingDefaulted.isEmpty ? '' : '，补齐方法缺 ${missingDefaulted.length} 个（引擎补齐）'}';
    }
    if (playOnly) {
      return '仅播放模式：缺核心方法 ${missingCore.join('、')}，仅 playerContent 可用';
    }
    return '校验不通过：缺核心方法 ${missingCore.join('、')}';
  }

  /// 形态不明时的失败原因（`ok` 为 false 时非空）。
  String get failureReason {
    if (ok) return '';
    if (!hasSpider) return '源码中未找到 class Spider，无法识别为 TVBox 蜘蛛';
    return '缺核心方法：${missingCore.join('、')}，且无 playerContent，无法注册';
  }
}

final RegExp _spiderClassPattern = RegExp(r'class\s+Spider\s*[:(]');

/// 校验一份 py 源码。
PyValidation validatePySource(String source) {
  final bool hasSpider = _spiderClassPattern.hasMatch(source);
  final present = <String>{};
  for (final method in <String>[...pyCoreMethods, ...pyDefaultedMethods]) {
    if (_hasMethod(source, method)) present.add(method);
  }
  final missingCore = pyCoreMethods
      .where((m) => !present.contains(m))
      .toList(growable: false);
  final missingDefaulted = pyDefaultedMethods
      .where((m) => !present.contains(m))
      .toList(growable: false);
  final playOnly =
      hasSpider && missingCore.isNotEmpty && present.contains('playerContent');
  return PyValidation(
    hasSpider: hasSpider,
    present: present,
    missingCore: missingCore,
    missingDefaulted: missingDefaulted,
    playOnly: playOnly,
    displayName: _extractDisplayName(source),
  );
}

bool _hasMethod(String source, String method) {
  // `def 方法名(` 或行首 `方法名 =`（赋值式定义）。
  if (RegExp('def\\s+$method\\s*\\(').hasMatch(source)) return true;
  return RegExp('^$method\\s*=', multiLine: true).hasMatch(source);
}

String? _extractDisplayName(String source) {
  final match = RegExp(
    "def\\s+getName\\s*\\([^)]*\\)[^:]*:\\s*(?:#[^\\n]*\\n\\s*)?return\\s*['\"]([^'\"]+)['\"]",
  ).firstMatch(source);
  final name = match?.group(1)?.trim();
  if (name == null || name.isEmpty) return null;
  return name;
}

/// JS 蜘蛛特征判定（与 py 导入共用入口时分流用）。
bool looksLikeJsSpider(String source) {
  return source.contains('function ') &&
      (source.contains('homeContent') || source.contains('detailContent'));
}
