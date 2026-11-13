import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/sources/pending_py_import.dart';
import 'package:wxyy/features/sources/presentation/py_import_sheet.dart';
import 'package:wxyy/features/sources/presentation/source_manager_screen.dart'
    show shouldShowShuyuanImportEntry;

/// 8 核心 + 6 补齐方法齐全的最小 py 蜘蛛。
const String _validPy = '''
class Spider:
    def getName(self):
        return "演示站"
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
    def searchContent(self, key, quick, pg="1"):
        return {}
    def playerContent(self, flag, id, vipFlags):
        return {}
    def localProxy(self, param):
        return [200, "text/plain", b""]
    def isVideoFormat(self, url):
        return False
    def manualVideoCheck(self):
        return False
    def action(self, action):
        return None
''';

/// 只有 getName 的残缺蜘蛛（缺核心方法且无 playerContent）。
const String _incompletePy = '''
class Spider:
    def getName(self):
        return "残缺站"
''';

/// JS 蜘蛛脚本（不是 Python）。
const String _jsSpider = '''
function homeContent() { return {}; }
function detailContent() { return {}; }
''';

void main() {
  group('PendingPyImport', () {
    test('valid py creates a pending import with py preview config', () {
      final pending =
          PendingPyImport.tryCreate(fileName: 'demo.py', code: _validPy);
      expect(pending, isNotNull);
      expect(pending!.fileName, 'demo.py');
      expect(pending.code, _validPy);
      final preview = pending.previewConfig;
      expect(preview.isPySource, isTrue);
      expect(preview.name, '演示站');
      expect(preview.type, SourceType.animeSource);
      expect(preview.spiderEngine!.sourceRef, 'file:demo');
      expect(preview.note, contains('校验通过'));
      expect(preview.validate(), isEmpty);
    });

    test('code without Spider class is rejected', () {
      expect(
        PendingPyImport.tryCreate(fileName: 'bad.py', code: 'x = 1'),
        isNull,
      );
      expect(
        PendingPyImport.failureReasonOf('x = 1'),
        contains('class Spider'),
      );
    });

    test('incomplete spider without playerContent is rejected', () {
      expect(
        PendingPyImport.tryCreate(fileName: 'half.py', code: _incompletePy),
        isNull,
      );
      expect(
        PendingPyImport.failureReasonOf(_incompletePy),
        contains('缺核心方法'),
      );
    });

    test('JS spider text reports the JS hint', () {
      expect(
        PendingPyImport.tryCreate(fileName: 's.py', code: _jsSpider),
        isNull,
      );
      expect(PendingPyImport.failureReasonOf(_jsSpider), contains('JS 蜘蛛'));
    });

    test('failureReasonOf is empty for valid code', () {
      expect(PendingPyImport.failureReasonOf(_validPy), isEmpty);
    });
  });

  group('PyImporter', () {
    test('validation failure registers nothing', () async {
      final repo = SourceRepository(<PluginConfig>[]);
      final outcome = await PyImporter.importCode(
        repo: repo,
        fileName: 'bad.py',
        code: 'x = 1',
      );
      expect(outcome.success, isFalse);
      expect(outcome.reason, isNotEmpty);
      expect(outcome.reason, contains('class Spider'));
      expect(repo.all, isEmpty);
      expect(repo.getById('bad'), isNull);
    });

    test('JS spider failure registers nothing', () async {
      final repo = SourceRepository(<PluginConfig>[]);
      final outcome = await PyImporter.importCode(
        repo: repo,
        fileName: 's.py',
        code: _jsSpider,
      );
      expect(outcome.success, isFalse);
      expect(outcome.reason, contains('JS 蜘蛛'));
      expect(repo.all, isEmpty);
    });

    test('idFromFileName derives ids', () {
      expect(PyImporter.idFromFileName('MissAV.py'), 'missav');
      expect(PyImporter.idFromFileName('my-site v2.py'), 'my_site_v2');
      expect(PyImporter.idFromFileName('.py'), 'py_source');
      expect(PyImporter.idFromFileName('dir/sub/demo.py'), 'demo');
    });
  });

  group('shouldShowShuyuanImportEntry', () {
    test('only novel source management shows the entry', () {
      expect(
        shouldShowShuyuanImportEntry(SourceType.novelSource),
        isTrue,
      );
      expect(
        shouldShowShuyuanImportEntry(SourceType.animeSource),
        isFalse,
      );
      expect(
        shouldShowShuyuanImportEntry(SourceType.mangaSource),
        isFalse,
      );
      expect(
        shouldShowShuyuanImportEntry(SourceType.audioSource),
        isFalse,
      );
      expect(shouldShowShuyuanImportEntry(null), isFalse);
    });
  });
}
