import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/features/miniapp/haikuo/haikuo_codec.dart';
import 'package:wxyy/features/miniapp/haikuo/haikuo_program.dart';
import 'package:wxyy/features/miniapp/mini_app_bridge.dart';
import 'package:wxyy/features/miniapp/mini_app_manifest.dart';
import 'package:wxyy/features/miniapp/mini_app_sources.dart';

void main() {
  group('内置小程序市场清单', () {
    test('market.json 可解析且有 17 条，全部合法', () {
      final file = File('assets/miniapps/builtin/market.json');
      expect(file.existsSync(), isTrue);
      final items = parseMiniAppMarketJson(file.readAsStringSync());
      expect(items.length, 17);
      for (final item in items) {
        expect(item.isValid, isTrue, reason: item.appId);
      }
      final ids = items.map((e) => e.appId).toSet();
      expect(ids.length, 17, reason: 'appId 不应重复');
      expect(ids.contains('com.ant.emby'), isTrue);
      expect(ids.contains('com.leospring.drpy_node'), isTrue);
    });

    test('每个 zip 包都在包内且 md5 与清单一致', () {
      final file = File('assets/miniapps/builtin/market.json');
      final items = parseMiniAppMarketJson(file.readAsStringSync());
      for (final item in items) {
        if (item.url.endsWith('.json')) {
          final manifestFile = File(
            'assets/miniapps/builtin/${item.appId}.manifest.json',
          );
          expect(
            manifestFile.existsSync(),
            isTrue,
            reason: item.appId,
          );
          final manifest = MiniAppManifest.fromJson(
            jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>,
          );
          expect(manifest.appId, item.appId);
          expect(manifest.isValid, isTrue);
          continue;
        }
        final zip = File('assets/miniapps/builtin/${item.appId}.zip');
        expect(zip.existsSync(), isTrue, reason: item.appId);
        if (item.md5 != null && item.size != null) {
          final bytes = zip.readAsBytesSync();
          expect(bytes.length, item.size, reason: item.appId);
          expect(md5.convert(bytes).toString(), item.md5, reason: item.appId);
        }
      }
    });
  });

  group('小程序 manifest 解析', () {
    test('字段、权限、网络白名单、python 入口', () {
      final manifest = MiniAppManifest.fromJson(<String, dynamic>{
        'appId': 'com.example.demo',
        'name': '示例',
        'version': '1.2.0',
        'versionCode': 3,
        'entry': 'index.html',
        'description': '说明',
        'permissions': ['network', 'player'],
        'network': {
          'allowlist': ['*.example.com'],
        },
        'python': {'entry': 'main.py'},
      });
      expect(manifest.isValid, isTrue);
      expect(manifest.hasPermission('player'), isTrue);
      expect(manifest.hasPermission('storage'), isFalse);
      expect(manifest.networkAllowlist, ['*.example.com']);
      expect(manifest.pythonEntry, 'main.py');
      expect(manifest.toJson()['appId'], 'com.example.demo');
    });

    test('非法 appId 不通过校验', () {
      final manifest = MiniAppManifest.fromJson(<String, dynamic>{
        'appId': 'Bad ID',
        'name': '示例',
      });
      expect(manifest.isValid, isFalse);
    });

    test('路径穿越被拦住', () {
      expect(safeJoinPath('/base', '../evil'), isNull);
      expect(safeJoinPath('/base', 'a/b.html'), isNotNull);
      expect(isSafeZipEntryName('../evil.sh'), isFalse);
      expect(isSafeZipEntryName('/abs.sh'), isFalse);
      expect(isSafeZipEntryName('manifest.json'), isTrue);
    });
  });

  group('海阔口令编解码往返', () {
    const rawRule = '{"title":"测试站","class_name":"分类一&分类二","sort":"最新&最热",'
        '"find_rule":"js:var d=[];setResult(d);"}';
    final program = HaikuoProgram(
      id: HaikuoProgram.makeId('测试站', rawRule),
      name: '测试站',
      script: 'js:var d=[];setResult(d);',
      kind: HaikuoKind.rule,
      rawJson: rawRule,
    );

    test('口令形态与载荷往返不丢字段', () {
      final code = HaikuoCodec.buildShareCode(program);
      expect(code.startsWith('海阔视界规则分享'), isTrue);
      expect(code.contains('￥home_rule￥'), isTrue);
      final candidates = HaikuoCodec.extractCandidates(code);
      List<HaikuoProgram>? parsed;
      for (final candidate in candidates) {
        final decoded = HaikuoCodec.tryBase64(candidate);
        if (decoded == null || decoded.isEmpty) continue;
        try {
          final programs = HaikuoCodec.parseBytes(decoded);
          if (programs.isNotEmpty) {
            parsed = programs;
            break;
          }
        } on HaikuoFormatException {
          continue;
        }
      }
      expect(parsed, isNotNull);
      expect(parsed!.length, 1);
      expect(parsed!.first.name, '测试站');
      expect(parsed!.first.rawJson.contains('class_name'), isTrue);
      expect(parsed!.first.rawJson.contains('sort'), isTrue);
    });

    test('shareJson 优先用原始 JSON', () {
      expect(HaikuoCodec.shareJson(program), rawRule);
    });

    test('makeId 稳定：同名同内容同 id，内容变则 id 变', () {
      expect(
        HaikuoProgram.makeId('测试站', rawRule),
        HaikuoProgram.makeId('测试站', rawRule),
      );
      expect(
        HaikuoProgram.makeId('测试站', rawRule),
        isNot(HaikuoProgram.makeId('测试站', '$rawRule ')),
      );
    });
  });

  group('海阔编解码', () {
    test('单规则对象解析为 rule', () {
      final programs = HaikuoCodec.parseText(
        '{"title":"测试站","find_rule":"js:var d=[];setResult(d);",'
        '"col_type":"movie_3"}',
      );
      expect(programs.length, 1);
      expect(programs.first.name, '测试站');
      expect(programs.first.kind, HaikuoKind.rule);
      // 规则按条目展示与打开，runnable 专指带可执行脚本的程序。
      expect(programs.first.runnable, isFalse);
    });

    test('包一层的 data 数组展开', () {
      final programs = HaikuoCodec.parseText(
        '{"data":[{"name":"甲","script":"1234567"},'
        '{"name":"乙","script":"7654321"}]}',
      );
      expect(programs.length, 2);
      expect(programs.map((e) => e.name).toSet(), {'甲', '乙'});
    });

    test('无法识别的格式抛人话异常', () {
      expect(
        () => HaikuoCodec.parseText('这不是小程序'),
        throwsA(isA<HaikuoFormatException>()),
      );
      expect(
        () => HaikuoCodec.parseText(''),
        throwsA(isA<HaikuoFormatException>()),
      );
    });

    test('云口令短码：云 6 有接口地址，其他云编号抛错', () {
      expect(
        HaikuoCodec.cloudApiUrl('云6oooole/xxxxxx/abc123'),
        'https://pasteme.tyrantg.com/api/getContent/abc123',
      );
      expect(
        () => HaikuoCodec.cloudApiUrl('云9oooole/xxxxxx/abc123'),
        throwsA(isA<HaikuoFormatException>()),
      );
      expect(HaikuoCodec.cloudApiUrl('普通口令'), isNull);
    });

    test('云剪贴板返回体解析', () {
      expect(
        HaikuoCodec.parseCloudApiResponse(
          '{"return_code":0,"data":"口令正文"}',
        ),
        '口令正文',
      );
      expect(
        () => HaikuoCodec.parseCloudApiResponse('{"return_code":1}'),
        throwsA(isA<HaikuoFormatException>()),
      );
    });
  });

  group('播放目标分流', () {
    test('媒体直链走 direct', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(url: 'https://cdn.example.com/a.m3u8?k=1'),
      );
      expect(target.isDirect, isTrue);
      expect(target.url, 'https://cdn.example.com/a.m3u8?k=1');
    });

    test('parse=1 时走 sniff，优先嗅探 playUrl', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(
          url: 'https://site.example.com/play?id=1',
          parse: '1',
          playUrl: 'https://jx.example.com/?url=xxx',
        ),
      );
      expect(target.isSniff, isTrue);
      expect(target.url, 'https://jx.example.com/?url=xxx');
    });

    test('parse=1 无 playUrl 时嗅探 url 本身', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(
          url: 'https://site.example.com/play?id=1',
          jx: '1',
        ),
      );
      expect(target.isSniff, isTrue);
      expect(target.url, 'https://site.example.com/play?id=1');
    });

    test('无解析声明的普通网页走 sniff', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(url: 'https://site.example.com/v/1.html'),
      );
      expect(target.isSniff, isTrue);
    });

    test('媒体地址分类只看后缀', () {
      expect(miniAppIsMediaUrl('https://a.example.com/x.mp4'), isTrue);
      expect(miniAppIsMediaUrl('https://a.example.com/x.m3u8'), isTrue);
      expect(miniAppIsMediaUrl('https://a.example.com/x.mp3'), isTrue);
      expect(miniAppIsMediaUrl('https://a.example.com/page.html'), isFalse);
      expect(miniAppIsMediaUrl('not a url'), isFalse);
    });
  });

  group('源桥归一化', () {
    test('normalizePlayResult：url 与 header 归一', () {
      final result = HostMiniAppSourceProvider.normalizePlayResult(
        <String, dynamic>{
          'url': 'https://cdn.example.com/a.m3u8',
          'header': {'Referer': 'https://site.example.com/'},
          'parse': true,
          'flag': '线路一',
        },
      );
      expect(result['url'], 'https://cdn.example.com/a.m3u8');
      expect(result['header'], {'Referer': 'https://site.example.com/'});
      expect(result['parse'], '1');
      expect(result['flag'], '线路一');
    });

    test('normalizePlayResult：无地址时抛错', () {
      expect(
        () => HostMiniAppSourceProvider.normalizePlayResult(
          <String, dynamic>{'header': <String, String>{}},
        ),
        throwsA(isA<MiniAppSourceFailure>()),
      );
    });

    test('normalizeHeaders 收三种形态', () {
      expect(
        HostMiniAppSourceProvider.normalizeHeaders(
          <String, dynamic>{'A': '1', 'B': 2},
        ),
        {'A': '1', 'B': '2'},
      );
      expect(
        HostMiniAppSourceProvider.normalizeHeaders('{"A":"1"}'),
        {'A': '1'},
      );
      expect(
        HostMiniAppSourceProvider.normalizeHeaders([
          ['A', '1'],
          {'key': 'B', 'value': '2'},
        ]),
        {'A': '1', 'B': '2'},
      );
      expect(HostMiniAppSourceProvider.normalizeHeaders(null), isEmpty);
    });

    test('withClassesAlias 补 classes 键，不覆盖已有值', () {
      final aliased = HostMiniAppSourceProvider.withClassesAlias(
        <String, dynamic>{
          'class': [
            {'type_id': '1', 'type_name': '分类一'},
          ],
          'list': [],
        },
      );
      expect(aliased['classes'], aliased['class']);
      final kept = HostMiniAppSourceProvider.withClassesAlias(
        <String, dynamic>{
          'class': [],
          'classes': [
            {'type_id': '9', 'type_name': '已有'},
          ],
        },
      );
      expect((kept['classes'] as List).length, 1);
    });
  });
}
