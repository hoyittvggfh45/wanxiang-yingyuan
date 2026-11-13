import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/spider/py_contract.dart';

PluginConfig _source() => const PluginConfig(
  id: 'test_site',
  name: '测试站',
  type: SourceType.animeSource,
  site: SiteConfig(domain: 'example.com', baseUrl: 'https://example.com'),
  parser: ParserConfig(type: 'py'),
);

void main() {
  group('vodListToItems', () {
    test('字段映射完整，缺 id/标题的跳过', () {
      final items = vodListToItems(<dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_name': '剧A',
          'vod_pic': 'https://example.com/a.jpg',
          'vod_content': '简介',
          'vod_director': '导演',
          'vod_actor': '演员',
          'vod_year': '2024',
          'vod_area': '大陆',
          'type_name': '剧集',
          'vod_remarks': '更新至10集',
        },
        <String, dynamic>{'vod_id': '', 'vod_name': '无id'},
        <String, dynamic>{'vod_id': '2', 'vod_name': ''},
      ], _source());
      expect(items.length, 1);
      final item = items.first;
      expect(item.id, '1');
      expect(item.title, '剧A');
      expect(item.coverUrl, 'https://example.com/a.jpg');
      expect(item.sourceId, 'test_site');
      expect(item.year, '2024');
      expect(item.tags, ['大陆', '剧集']);
      expect(item.status, '更新至10集');
    });
  });

  group('vodToEpisodes', () {
    test(r'$$$ 分线路、# 分集、$ 分名址', () {
      final episodes = vodToEpisodes(<String, dynamic>{
        'vod_id': 'v1',
        'vod_play_from': '线路一\$\$\$线路二',
        'vod_play_url': '第1集\$https://a/1.m3u8#第2集\$https://a/2.m3u8\$\$\$第1集\$https://b/1.m3u8',
      }, _source());
      expect(episodes.length, 3);
      expect(episodes[0].title, '第1集');
      expect(episodes[0].url, 'https://a/1.m3u8');
      expect(episodes[0].lineName, '线路一');
      expect(episodes[0].id, 'v1::0::0');
      expect(episodes[2].lineName, '线路二');
      expect(episodes[2].id, 'v1::1::0');
    });

    test('无名地址自动编号', () {
      final episodes = vodToEpisodes(<String, dynamic>{
        'vod_id': 'v1',
        'vod_play_url': 'https://a/1.m3u8#https://a/2.m3u8',
      }, _source());
      expect(episodes[0].title, '第 1 集');
      expect(episodes[1].title, '第 2 集');
    });

    test('空播放地址返回空列表', () {
      expect(
        vodToEpisodes(<String, dynamic>{'vod_id': 'v1'}, _source()),
        isEmpty,
      );
    });
  });

  group('playerResultToVideo', () {
    test('m3u8/mp4/dash 类型推断与 header 透传', () {
      final v = playerResultToVideo(<String, dynamic>{
        'url': 'https://a/x.m3u8',
        'header': {'Referer': 'https://example.com/'},
      });
      expect(v.type, 'm3u8');
      expect(v.headers?['Referer'], 'https://example.com/');
      expect(
        playerResultToVideo(<String, dynamic>{'url': 'https://a/x.mp4'}).type,
        'mp4',
      );
      expect(
        playerResultToVideo(<String, dynamic>{'url': 'https://a/x.mpd'}).type,
        'dash',
      );
    });

    test('空地址抛错', () {
      expect(
        () => playerResultToVideo(<String, dynamic>{'url': ''}),
        throwsStateError,
      );
    });
  });

  group('classListToCategories', () {
    test('type_id/type_name 映射', () {
      final cats = classListToCategories(<dynamic>[
        <String, dynamic>{'type_id': '1', 'type_name': '电影'},
        <String, dynamic>{'type_id': '2', 'type_name': '剧集'},
      ]);
      expect(cats.map((c) => c.title), ['电影', '剧集']);
      expect(cats.first.id, '1');
    });
  });
}
