import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/spider/py_spider_validator.dart';

const String _fullSpider = '''
class Spider:
    def getName(self):
        return "测试站"
    def getDependence(self):
        return []
    def init(self, extend=""):
        pass
    def destroy(self):
        pass
    def homeContent(self, filter):
        return {}
    def homeVideoContent(self):
        return {}
    def categoryContent(self, tid, pg, filter, extend):
        return {}
    def detailContent(self, ids):
        return {}
    def searchContent(self, key, quick, pg=1):
        return {}
    def playerContent(self, flag, id, vipFlags):
        return {}
    def localProxy(self, param):
        return []
    def isVideoFormat(self, url):
        return False
    def manualVideoCheck(self):
        return False
    def action(self, action):
        return None
''';

void main() {
  group('validatePySource', () {
    test('完整蜘蛛通过，显示名从 getName 抠出', () {
      final v = validatePySource(_fullSpider);
      expect(v.ok, isTrue);
      expect(v.hasSpider, isTrue);
      expect(v.missingCore, isEmpty);
      expect(v.displayName, '测试站');
    });

    test('无 class Spider 不通过', () {
      final v = validatePySource('x = 1\ndef foo():\n    pass\n');
      expect(v.ok, isFalse);
      expect(v.hasSpider, isFalse);
      expect(v.failureReason, contains('Spider'));
    });

    test('缺核心方法但有 playerContent 判仅播放模式', () {
      const code = '''
class Spider:
    def getName(self):
        return "X"
    def playerContent(self, flag, id, vipFlags):
        return {}
''';
      final v = validatePySource(code);
      expect(v.playOnly, isTrue);
      expect(v.ok, isTrue);
      expect(v.missingCore, isNotEmpty);
    });

    test('缺核心方法且无 playerContent 不通过', () {
      const code = '''
class Spider:
    def getName(self):
        return "X"
''';
      final v = validatePySource(code);
      expect(v.ok, isFalse);
      expect(v.failureReason, isNotEmpty);
    });

    test('JS 蜘蛛分流判定', () {
      const js = '''
function homeContent(filter) { return JSON.stringify({}); }
function detailContent(ids) { return JSON.stringify({}); }
var rule = { title: "X", host: "https://example.com" };
''';
      expect(looksLikeJsSpider(js), isTrue);
      expect(looksLikeJsSpider(_fullSpider), isFalse);
    });
  });
}
