import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/features/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:wxyy/features/miniapp/haikuo/haikuo_runtime_html.dart';

/// 刷新/重载后海报墙仍藏起：内嵌在播状态下页面（重）载完成时，
/// 藏海报墙的桥状态必须重下发；未在播时不发，桥调用失败不炸。
void main() {
  test('reload while inline playing re-issues hide-poster bridge call',
      () async {
    final scripts = <String>[];
    await restoreInlinePlayingOnPageFinished(
      inlineActive: true,
      runJavaScript: (script) async => scripts.add(script),
    );
    expect(scripts, hasLength(1));
    expect(scripts.single, contains('__haikuoSetInlinePlaying(true)'));
    // 桥调用打在运行时 HTML 真正定义的桥与藏海报墙规则上。
    expect(haikuoRuntimeHtml, contains('__haikuoSetInlinePlaying'));
    expect(haikuoRuntimeHtml, contains('hk-inline-playing'));
    expect(
      haikuoRuntimeHtml,
      contains('body.hk-inline-playing .d-head { display: none; }'),
    );
  });

  test('reload while not inline playing sends nothing', () async {
    final scripts = <String>[];
    await restoreInlinePlayingOnPageFinished(
      inlineActive: false,
      runJavaScript: (script) async => scripts.add(script),
    );
    expect(scripts, isEmpty);
  });

  test('bridge call failure is swallowed, never breaks playback', () async {
    await restoreInlinePlayingOnPageFinished(
      inlineActive: true,
      runJavaScript: (_) async => throw StateError('page not ready'),
    );
    // 没抛出来就算过：海报墙显隐失败不影响播放本身。
  });

  test('inline playing script toggles both ways with a defined-bridge guard',
      () {
    expect(
      haikuoInlinePlayingScript(true),
      'window.__haikuoSetInlinePlaying && '
      'window.__haikuoSetInlinePlaying(true);',
    );
    expect(
      haikuoInlinePlayingScript(false),
      'window.__haikuoSetInlinePlaying && '
      'window.__haikuoSetInlinePlaying(false);',
    );
  });
}
