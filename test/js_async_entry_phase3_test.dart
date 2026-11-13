/// JS 沙箱异步入口的 Phase3 解析回归：async 入口 + crypto 桥，无网络、确定性。
///
/// 本质规律（沉淀口径，无真实站点）：
/// - flutter_js 的 FFI QuickJS 把挂起 JS Promise 包成 pending Dart Future，
///   stringResult 为 "Instance of 'Future<dynamic>'" 且 isPromise 恒 false；
/// - Strategy B 的 async IIFE 重跑 + handlePromise（await rawResult + 20ms 泵）
///   是唯一把该形态落地为 JSON 字符串的通道；
/// - 同步入口不进 Phase3，直接走 Phase2 的严格 JSON 字符串路径。
///
/// 运行（需真 QuickJS 原生库在加载路径上）：
/// Linux：
/// LIBQUICKJSC_TEST_PATH="$HOME/.pub-cache/hosted/pub.dev/flutter_js-0.8.7/linux/shared/libquickjs_c_bridge_plugin.so" \
///   flutter test test/js_async_entry_phase3_test.dart
/// Windows：
/// PATH="/c/Users/yukai/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/flutter_js-0.8.7/windows/shared:$PATH" \
///   flutter test test/js_async_entry_phase3_test.dart
///
/// 原生库加载不到时用例跳过（非失败）：标准 `flutter test` 不带该
/// 环境变量，flutter_js 在测试环境下按裸名 dlopen 找不到 .so，
/// 引擎构造即抛错，与 Phase3 逻辑无关。是否跳过只按环境变量判定
/// （见下方 `_quickJsNativeLibAvailable`），不在注册期构造引擎探针。
/// 2026-11-13 已用上方 Linux 环境变量实跑：4 个用例全过。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/resolver/js_context.dart';

class _StaticBridge implements JsHostBridge {
  const _StaticBridge();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  String md5(String s) => crypto.md5.convert(utf8.encode(s)).toString();
}

FlutterJsEngine _engine() => FlutterJsEngine(const _StaticBridge(),
    baseUrl: 'https://site.example');

/// 探测 QuickJS 原生库能否加载：只看环境变量与文件是否存在，
/// 绝不在注册期构造引擎。注册期构造引擎会触发 flutter_js 的
/// enableFetch 建 HttpClient，flutter_test 的 mock 层调
/// printOnFailure 要求 test zone，注册期无 zone 会抛
/// no current invoker、整文件加载失败（2026-11-13 并行工人实测）。
/// 判定口径对齐 flutter_js 的加载规则（测试环境）：
/// Linux 看 LIBQUICKJSC_TEST_PATH 指向的文件是否存在，
/// Windows 看 PATH 里有没有 quickjs_c_bridge.dll，
/// macOS 走 DynamicLibrary.process()，默认可用。
bool _quickJsNativeLibAvailable() {
  if (Platform.isLinux) {
    final path = Platform.environment['LIBQUICKJSC_TEST_PATH'];
    return path != null && path.isNotEmpty && File(path).existsSync();
  }
  if (Platform.isWindows) {
    final pathVar = Platform.environment['PATH'] ?? '';
    return pathVar
        .split(';')
        .any((dir) => File('$dir\\quickjs_c_bridge.dll').existsSync());
  }
  return true;
}

/// 原生库缺失时的 skip 原因；库在则为 null（正常跑用例）。
String? get _skipWithoutQuickJs => _quickJsAvailable
    ? null
    : 'QuickJS 原生库未加载（需 LIBQUICKJSC_TEST_PATH 指向 flutter_js 的 .so）；'
        '带该环境变量跑 4 个用例全过。';

final bool _quickJsAvailable = _quickJsNativeLibAvailable();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同步入口：Phase2 直接返回严格 JSON（不进 Phase3）', () async {
    final engine = _engine();
    final out = await engine.run('function f(raw, context) { return {a: 1}; }',
        'f', <dynamic>['x']);
    expect(out, isA<Map<dynamic, dynamic>>());
    expect((out as Map)['a'], 1);
  }, skip: _skipWithoutQuickJs);

  test('async 入口：await context.crypto.md5 后返回对象，经 Phase3 落地', () async {
    final engine = _engine();
    // async 入口内部走 crypto 桥（Dart 侧 md5 无网络）→ Promise settle →
    // Strategy B（Dart-Future 识别 + handlePromise）必须拿到字符串化结果。
    const script = '''
function parseList(raw, context) {
  return context.crypto.md5(String(raw || '')).then(function (h) {
    return { kind: 'meta', hash: h, echo: raw };
  });
}
''';
    final out = await engine.run(script, 'parseList', <dynamic>['hello']);
    expect(out, isA<Map<dynamic, dynamic>>());
    final map = out as Map<dynamic, dynamic>;
    expect(map['kind'], 'meta');
    expect(map['echo'], 'hello');
    expect(map['hash'], crypto.md5.convert(utf8.encode('hello')).toString(),
        reason: 'md5 桥往返结果应与 Dart 侧基准一致');
  }, skip: _skipWithoutQuickJs);

  test('async 入口返回 List：Phase3 后仍解码为 List', () async {
    final engine = _engine();
    const script = '''
function parseEpisodes(raw, context) {
  return context.crypto.md5('x').then(function () {
    return [{id: '1', url: 'u1'}, {id: '2', url: 'u2'}];
  });
}
''';
    final out = await engine.run(script, 'parseEpisodes', <dynamic>['']);
    expect(out, isA<List<dynamic>>());
    expect((out as List).length, 2);
  }, skip: _skipWithoutQuickJs);

  test('async 入口抛错：Phase3 落地为 null（不炸整页）', () async {
    final engine = _engine();
    const script = '''
function parseDetail(raw, context) {
  return context.crypto.md5('x').then(function () {
    throw new Error('boom');
  });
}
''';
    final out = await engine.run(script, 'parseDetail', <dynamic>['']);
    expect(out, isNull,
        reason: 'Phase3-B 的 IIFE catch 应返回 JSON.stringify(null)');
  }, skip: _skipWithoutQuickJs);
}
