/// 蜘蛛引擎异常：py / jar 引擎未接通或调用失败时抛出。
///
/// UI 层据 [notConnected] 展示诚实状态（“引擎未接通”），而非把失败
/// 伪装成“暂无内容”。
library;

class SpiderEngineException implements Exception {
  SpiderEngineException(this.message, {this.notConnected = false});

  final String message;

  /// true = 原生引擎尚未接通（桩），不是源本身的问题。
  final bool notConnected;

  @override
  String toString() => message;
}

/// 引擎未接通时的统一提示（Dart 侧与原生桩共用同一文案）。
const String spiderEngineNotConnectedMessage =
    '蜘蛛引擎未接通：本版本尚未集成 Python / Java 运行环境，py 与 jar 源暂时无法播放。';
