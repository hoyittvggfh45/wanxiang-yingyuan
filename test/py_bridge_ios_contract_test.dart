/// iOS py 引擎桥契约测试：Dart 侧 `PyBridge` 与 iOS 原生侧
/// `PySpiderBridge.m` 的约定，与安卓侧 `SpiderBridge.kt` 同一条协议。
///
/// 原生实现无法在主机测试里跑，这里用 mock 通道扮演原生侧，按
/// `ios/Runner/PySpiderBridge.m` 的约定回包，验 Dart 侧的收发与报错映射。
/// 真机上的解释器初始化与真站调用一律未验。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/spider/spider_bridges.dart';
import 'package:wxyy/core/spider/spider_errors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pyChannel = MethodChannel('wxyy/pybridge');

  MethodCall? lastCall;

  void setMock(Future<dynamic> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pyChannel, (MethodCall call) async {
      lastCall = call;
      return handler(call);
    });
  }

  setUp(() {
    lastCall = null;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pyChannel, null);
  });

  test('status 接通时 isConnected 为 true', () async {
    setMock((MethodCall call) async {
      expect(call.method, 'status');
      return <String, dynamic>{
        'connected': true,
        'python': '3.13.18',
        'requests': true,
      };
    });
    expect(await PyBridge.isConnected(), isTrue);
  });

  test('status 未接通时 isConnected 为 false', () async {
    setMock((MethodCall call) async {
      return <String, dynamic>{
        'connected': false,
        'error': 'Python 解释器启动失败',
      };
    });
    expect(await PyBridge.isConnected(), isFalse);
  });

  test('call 按约定发包：siteId/method/args，源码随 args[source]', () async {
    const source = 'class Spider:\n  pass\n';
    setMock((MethodCall call) async {
      expect(call.method, 'call');
      final args = call.arguments as Map<dynamic, dynamic>;
      expect(args['siteId'], 's1');
      expect(args['method'], 'homeContent');
      final callArgs = args['args'] as Map<dynamic, dynamic>;
      expect(callArgs['source'], source);
      expect(callArgs['filter'], isFalse);
      return <String, dynamic>{
        'class': <dynamic>[],
        'list': <dynamic>[],
      };
    });
    final result = await PyBridge.call('s1', 'homeContent', <String, dynamic>{
      'source': source,
      'filter': false,
    });
    expect(result, containsPair('list', <dynamic>[]));
    expect(lastCall, isNotNull);
  });

  test('call 收到 SPIDER_ERROR 时透传真实原因', () async {
    setMock((MethodCall call) async {
      throw PlatformException(
        code: 'SPIDER_ERROR',
        message: 'ValueError: 蜘蛛执行失败',
      );
    });
    try {
      await PyBridge.call('s1', 'homeContent', <String, dynamic>{});
      fail('应当抛 SpiderEngineException');
    } on SpiderEngineException catch (e) {
      expect(e.notConnected, isFalse);
      expect(e.message, contains('ValueError: 蜘蛛执行失败'));
    }
  });

  test('call 收到 NOT_CONNECTED 时报未接通', () async {
    setMock((MethodCall call) async {
      throw PlatformException(
        code: 'NOT_CONNECTED',
        message: 'Python 解释器启动失败',
      );
    });
    try {
      await PyBridge.call('s1', 'homeContent', <String, dynamic>{});
      fail('应当抛 SpiderEngineException');
    } on SpiderEngineException catch (e) {
      expect(e.notConnected, isTrue);
      expect(e.message, spiderEngineNotConnectedMessage);
    }
  });

  test('call 返回空结果时抛异常', () async {
    setMock((MethodCall call) async => null);
    try {
      await PyBridge.call('s1', 'homeContent', <String, dynamic>{});
      fail('应当抛 SpiderEngineException');
    } on SpiderEngineException catch (e) {
      expect(e.message, contains('空结果'));
    }
  });

  test('无原生处理时（MissingPlugin）报未接通', () async {
    // 不设 mock：通道无处理方，抛 MissingPluginException。
    try {
      await PyBridge.call('s1', 'homeContent', <String, dynamic>{});
      fail('应当抛 SpiderEngineException');
    } on SpiderEngineException catch (e) {
      expect(e.notConnected, isTrue);
    }
    expect(await PyBridge.isConnected(), isFalse);
  });

  test('release 发包且失败不抛', () async {
    var released = <String>[];
    setMock((MethodCall call) async {
      expect(call.method, 'release');
      final args = call.arguments as Map<dynamic, dynamic>;
      released.add(args['siteId'] as String);
      return null;
    });
    await PyBridge.release('s1');
    expect(released, <String>['s1']);

    setMock((MethodCall call) async {
      throw PlatformException(code: 'ENGINE_ERROR', message: 'boom');
    });
    await PyBridge.release('s1');
  });
}
