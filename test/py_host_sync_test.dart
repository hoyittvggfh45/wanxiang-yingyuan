/// iOS py 引擎打包物静态守卫：宿主文件双份同步、纯 Python 包齐全、
/// XCFramework 关键件在位。跑在主机上，只读文件，不启动解释器。
///
/// 宿主协议文件安卓与 iOS 各一份，必须逐字节相同——改一处就要同步另一处，
/// 否则两边行为分叉。此测试在漂移时失败并明说该同步哪两个文件。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: '缺文件：$relativePath');
  return file.readAsStringSync();
}

void main() {
  group('宿主文件双份同步（安卓 = iOS）', () {
    test('py_spider_host.py 两份逐字节相同', () {
      final android = _read('android/app/src/main/python/py_spider_host.py');
      final ios = _read('ios/pycode/py_spider_host.py');
      expect(
        ios,
        android,
        reason: 'ios/pycode/py_spider_host.py 与安卓侧不一致，'
            '改宿主协议时两份必须同步',
      );
    });

    test('base/spider.py 两份逐字节相同', () {
      final android = _read('android/app/src/main/python/base/spider.py');
      final ios = _read('ios/pycode/base/spider.py');
      expect(
        ios,
        android,
        reason: 'ios/pycode/base/spider.py 与安卓侧不一致，改基类时两份必须同步',
      );
    });
  });

  group('iOS 纯 Python 包（py_packages）', () {
    const packages = <String>[
      'requests',
      'urllib3',
      'certifi',
      'idna',
      'charset_normalizer',
    ];

    for (final name in packages) {
      test('$name 在位', () {
        expect(Directory('ios/py_packages/$name').existsSync(), isTrue);
      });
    }

    test('无任何二进制扩展（.so/.dylib/.pyd）', () {
      final binaries = Directory('ios/py_packages')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) =>
              f.path.endsWith('.so') ||
              f.path.endsWith('.dylib') ||
              f.path.endsWith('.pyd'))
          .map((File f) => f.path)
          .toList();
      expect(binaries, isEmpty, reason: 'py_packages 里混入了二进制扩展：$binaries');
    });

    test('certifi 带证书包', () {
      expect(File('ios/py_packages/certifi/cacert.pem').existsSync(), isTrue);
    });
  });

  group('Python.xcframework 关键件', () {
    test('Info.plist 与双 slice 在位', () {
      expect(File('ios/Python.xcframework/Info.plist').existsSync(), isTrue);
      expect(
        File('ios/Python.xcframework/ios-arm64/Python.framework/Python')
            .existsSync(),
        isTrue,
      );
      expect(
        File('ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python')
            .existsSync(),
        isTrue,
      );
    });

    test('构建脚本 utils.sh 与 dylib 模板在位', () {
      expect(File('ios/Python.xcframework/build/utils.sh').existsSync(), isTrue);
      expect(
        File('ios/Python.xcframework/build/iOS-dylib-Info-template.plist')
            .existsSync(),
        isTrue,
      );
    });

    test('标准库与 _ssl 扩展在位', () {
      expect(
        Directory('ios/Python.xcframework/lib/python3.13').existsSync(),
        isTrue,
      );
      expect(
        File('ios/Python.xcframework/lib/python3.13/ssl.py').existsSync(),
        isTrue,
      );
      final dynload =
          Directory('ios/Python.xcframework/ios-arm64/lib-arm64/python3.13/lib-dynload');
      expect(dynload.existsSync(), isTrue);
      final hasSsl = dynload
          .listSync()
          .whereType<File>()
          .any((File f) => f.path.contains('_ssl'));
      expect(hasSsl, isTrue, reason: '设备 slice 缺 _ssl 扩展，HTTPS 跑不起来');
    });

    test('C 头文件在位（供桥编译）', () {
      expect(
        File('ios/Python.xcframework/ios-arm64/Python.framework/Headers/Python.h')
            .existsSync(),
        isTrue,
      );
    });
  });

  group('原生桥文件', () {
    test('PySpiderBridge.h/.m 在位', () {
      expect(File('ios/Runner/PySpiderBridge.h').existsSync(), isTrue);
      expect(File('ios/Runner/PySpiderBridge.m').existsSync(), isTrue);
    });

    test('桥接头与 AppDelegate 接了桥', () {
      final bridging = _read('ios/Runner/Runner-Bridging-Header.h');
      expect(bridging, contains('PySpiderBridge.h'));
      final delegate = _read('ios/Runner/AppDelegate.swift');
      expect(delegate, contains('PySpiderBridge.register'));
    });

    test('桥实现含三方法与解释器初始化关键调用', () {
      final impl = _read('ios/Runner/PySpiderBridge.m');
      expect(impl, contains('wxyy/pybridge'));
      expect(impl, contains('handle_json'));
      expect(impl, contains('status_json'));
      expect(impl, contains('release_json'));
      expect(impl, contains('Py_InitializeFromConfig'));
      expect(impl, contains('PyConfig_InitIsolatedConfig'));
      expect(impl, contains('py_spider_host'));
      expect(impl, contains('NOT_CONNECTED'));
    });

    test('工程文件含 Python 构建相位与搜索路径', () {
      final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(pbx, contains('Process Python libraries'));
      expect(pbx, contains('install_python Python.xcframework pycode py_packages'));
      expect(pbx, contains('Python.xcframework in Embed Frameworks'));
      expect(pbx, contains('PySpiderBridge.m in Sources'));
      expect(pbx, contains('FRAMEWORK_SEARCH_PATHS'));
      expect(pbx, contains('Python.framework/Headers'));
    });
  });
}
