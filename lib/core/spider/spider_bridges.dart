/// 蜘蛛引擎 Dart 侧桥：经 MethodChannel 调安卓原生侧的 py / jar 引擎。
///
/// 原生侧见 `android/.../SpiderBridge.kt`：py 走 Chaquopy 嵌 Python 解释器
/// 执行蜘蛛源码，jar 走 DexClassLoader 加载站点 jar 并反射调用蜘蛛类。
/// 引擎不可用时原生报 NOT_CONNECTED，Dart 侧翻译成
/// [SpiderEngineException.notConnected]，绝不假装成功；蜘蛛执行失败时
/// 原生带真实原因回，Dart 侧原样透传。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'spider_errors.dart';

/// 单次蜘蛛调用的最长等待：站方网络慢时也封顶，避免界面无限转圈。
const Duration _spiderCallTimeout = Duration(seconds: 60);

class PyBridge {
  PyBridge._();

  static const MethodChannel _channel = MethodChannel('wxyy/pybridge');

  /// 引擎是否已接通（原生返回 `{'connected': true}`；未接通/缺插件均 false）。
  static Future<bool> isConnected() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'status',
      );
      return result?['connected'] == true;
    } on Object {
      return false;
    }
  }

  /// 调用蜘蛛方法：[siteId] 为源 id，[method] 为 TVBox 方法名
  ///（`homeContent` / `categoryContent` / `detailContent` / `searchContent` /
  /// `playerContent` / `homeVideoContent`），[args] 为方法参数。
  ///
  /// 返回蜘蛛的 JSON 结果（Map）。引擎未接通时抛 [SpiderEngineException]。
  static Future<Map<String, dynamic>> call(
    String siteId,
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>(
            'call',
            <String, dynamic>{'siteId': siteId, 'method': method, 'args': args},
          )
          .timeout(_spiderCallTimeout);
      if (result == null) {
        throw SpiderEngineException('Python 引擎返回空结果');
      }
      return Map<String, dynamic>.from(result);
    } on SpiderEngineException {
      rethrow;
    } on TimeoutException {
      throw SpiderEngineException('Python 引擎调用超时（60 秒），蜘蛛可能在等网络响应');
    } on PlatformException catch (e) {
      throw _asEngineException(e, 'Python');
    } on MissingPluginException {
      throw SpiderEngineException(
        spiderEngineNotConnectedMessage,
        notConnected: true,
      );
    }
  }

  /// 释放某站点的蜘蛛实例（原生侧销毁实例；释放失败不影响调用方）。
  static Future<void> release(String siteId) async {
    try {
      await _channel.invokeMethod<void>('release', {'siteId': siteId});
    } on Object {
      // 释放失败不影响调用方。
    }
  }
}

class JarBridge {
  JarBridge._();

  static const MethodChannel _channel = MethodChannel('wxyy/jarbridge');

  /// 引擎是否已接通（原生返回 `{'connected': true}`；未接通/缺插件均 false）。
  static Future<bool> isConnected() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'status',
      );
      return result?['connected'] == true;
    } on Object {
      return false;
    }
  }

  /// 调用 jar 蜘蛛方法：[siteId] 为源 id，[api] 为 `csp_...`，[ext] 为 ext
  /// 参数，[method] 与 [args] 同 [PyBridge.call]。
  static Future<Map<String, dynamic>> call(
    String siteId,
    String api,
    String ext,
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>(
            'call',
            <String, dynamic>{
              'siteId': siteId,
              'api': api,
              'ext': ext,
              'method': method,
              'args': args,
            },
          )
          .timeout(_spiderCallTimeout);
      if (result == null) {
        throw SpiderEngineException('Java 引擎返回空结果');
      }
      return Map<String, dynamic>.from(result);
    } on SpiderEngineException {
      rethrow;
    } on TimeoutException {
      throw SpiderEngineException('Java 引擎调用超时（60 秒），蜘蛛可能在等网络响应');
    } on PlatformException catch (e) {
      throw _asEngineException(e, 'Java');
    } on MissingPluginException {
      throw SpiderEngineException(
        spiderEngineNotConnectedMessage,
        notConnected: true,
      );
    }
  }

  /// 释放某站点的蜘蛛实例（原生侧销毁实例；释放失败不影响调用方）。
  static Future<void> release(String siteId) async {
    try {
      await _channel.invokeMethod<void>('release', {'siteId': siteId});
    } on Object {
      // 释放失败不影响调用方。
    }
  }
}

SpiderEngineException _asEngineException(PlatformException e, String engine) {
  if (e.code == 'NOT_CONNECTED') {
    return SpiderEngineException(
      spiderEngineNotConnectedMessage,
      notConnected: true,
    );
  }
  return SpiderEngineException('$engine 引擎调用失败：${e.message ?? e.code}');
}
