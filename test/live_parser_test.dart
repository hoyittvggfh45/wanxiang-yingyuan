import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/live/live_parser.dart';

void main() {
  group('LiveParser M3U', () {
    test('解析分组、台标与地址', () {
      const String text = '''
#EXTM3U
#EXTINF:-1 tvg-logo="https://example.com/a.png" group-title="新闻",央视一套
https://example.com/cctv1.m3u8
#EXTINF:-1 group-title="新闻",央视二套
https://example.com/cctv2.m3u8
#EXTINF:-1 group-title="体育",体育频道
https://example.com/sports.m3u8
''';
      final result = LiveParser.parse(text);
      expect(result.totalChannels, 3);
      expect(result.groups.map((g) => g.name), ['新闻', '体育']);
      final first = result.groups.first.channels.first;
      expect(first.name, '央视一套');
      expect(first.logo, 'https://example.com/a.png');
      expect(first.url, 'https://example.com/cctv1.m3u8');
      expect(first.playable, isTrue);
    });

    test('同名同组连续条目合并为多地址', () {
      const String text = '''
#EXTM3U
#EXTINF:-1 group-title="综合",频道A
https://a.example.com/1.m3u8
#EXTINF:-1 group-title="综合",频道A
https://b.example.com/2.m3u8
''';
      final result = LiveParser.parse(text);
      expect(result.totalChannels, 1);
      expect(result.groups.first.channels.first.urls.length, 2);
    });

    test('缺分组进未分组', () {
      const String text = '''
#EXTM3U
#EXTINF:-1,无名频道
https://example.com/x.m3u8
''';
      final result = LiveParser.parse(text);
      expect(result.groups.first.name, '未分组');
    });
  });

  group('LiveParser 文本格式', () {
    test('组头 + 频道行', () {
      const String text = '''
新闻,#genre#
央视一套,https://example.com/cctv1.m3u8
体育,#genre#
体育频道,https://example.com/sports.m3u8
''';
      final result = LiveParser.parse(text);
      expect(result.totalChannels, 2);
      expect(result.groups.map((g) => g.name), ['新闻', '体育']);
    });

    test('空文本解析为空', () {
      expect(LiveParser.parse('').isEmpty, isTrue);
      expect(LiveParser.parse('#EXTM3U\n').isEmpty, isTrue);
    });
  });
}
