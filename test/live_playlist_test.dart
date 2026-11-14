import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/live/live_models.dart';
import 'package:wxyy/core/live/live_playlist.dart';

LiveChannel channel(String name, List<String> urls, {String group = '综合'}) =>
    LiveChannel(key: '$group::$name', name: name, urls: urls, group: group);

void main() {
  group('LivePlaylist 选台', () {
    test('初始下标越界 clamp，空表 channel 为 null、url 为空', () {
      final empty = LivePlaylist(channels: const <LiveChannel>[]);
      expect(empty.channel, isNull);
      expect(empty.url, '');
      expect(empty.playable, isFalse);

      final list = LivePlaylist(
        channels: <LiveChannel>[channel('A', <String>['https://a/1.m3u8'])],
        index: 9,
      );
      expect(list.index, 0);
      expect(list.channel?.name, 'A');
      expect(list.url, 'https://a/1.m3u8');
    });

    test('上一台/下一台越界环绕，切台后线路归零', () {
      final list = LivePlaylist(
        channels: <LiveChannel>[
          channel('A', <String>['https://a/1', 'https://a/2']),
          channel('B', <String>['https://b/1']),
          channel('C', <String>['https://c/1']),
        ],
      );
      list.playRoute(1);
      expect(list.url, 'https://a/2');
      list.switchBy(1);
      expect(list.channel?.name, 'B');
      expect(list.route, 0);
      list.switchBy(1);
      expect(list.channel?.name, 'C');
      list.switchBy(1);
      expect(list.channel?.name, 'A');
      list.switchBy(-1);
      expect(list.channel?.name, 'C');
    });

    test('换线路 clamp，单台不环绕', () {
      final list = LivePlaylist(
        channels: <LiveChannel>[
          channel('A', <String>['https://a/1', 'https://a/2']),
        ],
      );
      expect(list.hasMultipleRoutes, isTrue);
      expect(list.hasUntriedRoute, isTrue);
      list.playRoute(9);
      expect(list.route, 1);
      expect(list.url, 'https://a/2');
      expect(list.hasUntriedRoute, isFalse);
      list.switchBy(1);
      expect(list.index, 0);
    });

    test('play 越界 clamp 且线路归零，indexOfKey 找不到返回 -1', () {
      final list = LivePlaylist(
        channels: <LiveChannel>[
          channel('A', <String>['https://a/1', 'https://a/2']),
          channel('B', <String>['https://b/1']),
        ],
      );
      list.playRoute(1);
      list.play(99);
      expect(list.index, 1);
      expect(list.route, 0);
      expect(list.indexOfKey('综合::A'), 0);
      expect(list.indexOfKey('不存在'), -1);
    });

    test('不可播频道 playable 为 false', () {
      final list = LivePlaylist(
        channels: <LiveChannel>[channel('X', <String>[''])],
      );
      expect(list.playable, isFalse);
      expect(list.url, '');
    });
  });

  group('flattenLiveGroups', () {
    test('按分组顺序拼平', () {
      final groups = <LiveGroup>[
        LiveGroup(
          name: '新闻',
          channels: <LiveChannel>[channel('A', <String>['https://a'])],
        ),
        LiveGroup(
          name: '体育',
          channels: <LiveChannel>[
            channel('B', <String>['https://b']),
            channel('C', <String>['https://c']),
          ],
        ),
      ];
      expect(
        flattenLiveGroups(groups).map((c) => c.name),
        <String>['A', 'B', 'C'],
      );
    });
  });
}
