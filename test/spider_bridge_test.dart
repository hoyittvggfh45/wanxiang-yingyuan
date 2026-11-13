import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/spider/spider_bridges.dart';
import 'package:wxyy/core/spider/spider_errors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('蜘蛛引擎诚实报错（原生桩未接通）', () {
    const pyChannel = MethodChannel('wxyy/pybridge');
    const jarChannel = MethodChannel('wxyy/jarbridge');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pyChannel, (MethodCall call) async {
            if (call.method == 'status') {
              return <String, dynamic>{'connected': false};
            }
            throw PlatformException(
              code: 'NOT_CONNECTED',
              message: spiderEngineNotConnectedMessage,
            );
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(jarChannel, (MethodCall call) async {
            if (call.method == 'status') {
              return <String, dynamic>{'connected': false};
            }
            throw PlatformException(
              code: 'NOT_CONNECTED',
              message: spiderEngineNotConnectedMessage,
            );
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pyChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(jarChannel, null);
    });

    test('py 引擎 status 报告未接通', () async {
      expect(await PyBridge.isConnected(), isFalse);
    });

    test('jar 引擎 status 报告未接通', () async {
      expect(await JarBridge.isConnected(), isFalse);
    });

    test('py 调用抛 notConnected 异常', () async {
      try {
        await PyBridge.call('s1', 'homeContent', <String, dynamic>{});
        fail('应当抛 SpiderEngineException');
      } on SpiderEngineException catch (e) {
        expect(e.notConnected, isTrue);
        expect(e.message, contains('未接通'));
      }
    });

    test('jar 调用抛 notConnected 异常', () async {
      try {
        await JarBridge.call(
          's1',
          'csp_Test',
          '',
          'homeContent',
          <String, dynamic>{},
        );
        fail('应当抛 SpiderEngineException');
      } on SpiderEngineException catch (e) {
        expect(e.notConnected, isTrue);
        expect(e.message, contains('未接通'));
      }
    });
  });
}
