/// 红果核心移植单元测试：签名/摘要、账号掩码与记录分离、退避轮换、
/// 响应解析、取流选择、网页兜底（假传输），不依赖真实接口。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wxyy/core/hongguo/hongguo_app_client.dart';
import 'package:wxyy/core/hongguo/hongguo_device.dart';
import 'package:wxyy/core/hongguo/hongguo_http.dart';
import 'package:wxyy/core/hongguo/hongguo_models.dart';
import 'package:wxyy/core/hongguo/hongguo_playback_codec.dart';
import 'package:wxyy/core/hongguo/hongguo_playback_policy.dart';
import 'package:wxyy/core/hongguo/hongguo_ranking.dart';
import 'package:wxyy/core/hongguo/hongguo_signing.dart';
import 'package:wxyy/core/hongguo/hongguo_sm3.dart';
import 'package:wxyy/core/hongguo/hongguo_web_client.dart';
import 'package:wxyy/features/hongguo/hongguo_account.dart';
import 'package:wxyy/features/hongguo/hongguo_records.dart';

class _FakeSigner implements HongguoRequestSigner {
  @override
  Map<String, String> sign({
    required String rawQuery,
    required List<int>? body,
    required String deviceId,
    required String aid,
    required DateTime now,
    required bool comment,
  }) =>
      <String, String>{'X-Test-Sign': 'fixed'};
}

class _FakeTransport implements HongguoTransport {
  _FakeTransport({
    this.getHandler,
    this.postHandler,
    this.headHandler,
  });

  final HongguoHttpResponse Function(Uri uri)? getHandler;
  final HongguoHttpResponse Function(Uri uri)? postHandler;
  final HongguoHttpResponse Function(Uri uri)? headHandler;

  @override
  Future<HongguoHttpResponse> get(Uri uri,
          {Map<String, String> headers = const <String, String>{}}) async =>
      getHandler?.call(uri) ??
      const HongguoHttpResponse(statusCode: 404, body: '');

  @override
  Future<HongguoHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
  }) async =>
      postHandler?.call(uri) ??
      const HongguoHttpResponse(statusCode: 404, body: '');

  @override
  Future<HongguoHttpResponse> head(Uri uri,
          {Map<String, String> headers = const <String, String>{}}) async =>
      headHandler?.call(uri) ??
      const HongguoHttpResponse(statusCode: 404, body: '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    hongguoAccountNotifier.value = null;
  });

  group('SM3 与签名部件', () {
    test('SM3 空输入固定输出', () {
      expect(
        hongguoHexEncode(hongguoSm3(<int>[])),
        '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b',
      );
    });

    test('SM3 abc 固定输出', () {
      expect(
        hongguoHexEncode(hongguoSm3(utf8.encode('abc'))),
        '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
      );
    });

    test('SM3 相同输入相同输出、不同输入不同输出', () {
      final List<int> first = hongguoSm3(utf8.encode('红果'));
      final List<int> second = hongguoSm3(utf8.encode('红果'));
      final List<int> other = hongguoSm3(utf8.encode('黄果'));
      expect(first, second);
      expect(first, isNot(other));
      expect(first.length, 32);
    });

    test('X-SS-STUB 为请求体 MD5 大写十六进制', () {
      expect(hongguoBodyStub(utf8.encode('hello')),
          '5D41402ABC4B2A76B9719D911017C592');
      expect(hongguoBodyStub(null), '');
    });

    test('无密钥通用头含秒级与毫秒级时间戳', () {
      final DateTime now = DateTime.fromMillisecondsSinceEpoch(1794499000123);
      final Map<String, String> headers = hongguoUnsignedHeaders(now);
      expect(headers['X-Khronos'], '1794499000');
      expect(headers['X-SS-Req-Ticket'], '1794499000123');
    });

    test('默认签名器抛签名缺项，不伪造签名头', () {
      expect(
        () => const HongguoUnsignedSigner().sign(
          rawQuery: 'aid=8662',
          body: null,
          deviceId: '1',
          aid: '8662',
          now: DateTime.now(),
          comment: false,
        ),
        throwsA(isA<HongguoSigningUnavailable>()),
      );
    });

    test('随机 nonce 为 11 字节且两次不同', () {
      final List<int> first = hongguoRandomNonce();
      final List<int> second = hongguoRandomNonce();
      expect(first.length, 11);
      expect(first, isNot(second));
    });
  });

  group('账号掩码与记录分离', () {
    test('手机号掩码', () {
      expect(HongguoAccount.maskPhone('13812345678'), '138****5678');
      expect(HongguoAccount.maskPhone('123'), '123');
      expect(HongguoAccount.maskPhone(''), '');
    });

    test('账号状态取值', () {
      hongguoAccountNotifier.value = const HongguoAccount(
        userId: '1001',
        displayName: '道友',
        maskedPhone: '138****5678',
        method: 'sms',
      );
      expect(hongguoAccountDisplayLabel(), '138****5678');
      hongguoAccountNotifier.value = null;
      expect(hongguoAccountDisplayLabel(), '未登录');
    });

    test('本机记录与账号记录分开存、互不干扰', () async {
      final HongguoRecordStore local = hongguoLocalRecords();
      await local.addFavorite(const HongguoFavoriteRecord(
        seriesId: '111',
        title: '本机剧',
        updatedAt: 1,
      ));
      hongguoAccountNotifier.value = const HongguoAccount(
        userId: 'userA',
        displayName: '甲',
        method: 'sms',
      );
      final HongguoRecordStore? accountA = hongguoAccountRecords();
      expect(accountA, isNotNull);
      await accountA!.addFavorite(const HongguoFavoriteRecord(
        seriesId: '222',
        title: '账号剧',
        updatedAt: 2,
      ));
      // 本机存储不受账号写入影响。
      final List<HongguoFavoriteRecord> localFavorites =
          await local.favorites();
      expect(
          localFavorites.map((HongguoFavoriteRecord record) => record.seriesId),
          <String>['111']);
      // 换账号后看不到上个账号的记录。
      hongguoAccountNotifier.value = const HongguoAccount(
        userId: 'userB',
        displayName: '乙',
        method: 'sms',
      );
      final HongguoRecordStore? accountB = hongguoAccountRecords();
      expect(await accountB!.favorites(), isEmpty);
      // 切回账号 A，记录仍在。
      hongguoAccountNotifier.value = const HongguoAccount(
        userId: 'userA',
        displayName: '甲',
        method: 'sms',
      );
      final List<HongguoFavoriteRecord> favoritesA =
          await hongguoAccountRecords()!.favorites();
      expect(favoritesA.map((HongguoFavoriteRecord record) => record.seriesId),
          <String>['222']);
      // 未登录时账号存储为 null。
      hongguoAccountNotifier.value = null;
      expect(hongguoAccountRecords(), isNull);
    });

    test('续播记录保存与播完判定', () async {
      final HongguoRecordStore local = hongguoLocalRecords();
      await local.saveProgress(const HongguoProgressRecord(
        seriesId: '333',
        title: '续播剧',
        episodeIndex: 5,
        positionMs: 59000,
        durationMs: 60000,
        updatedAt: 3,
      ));
      final HongguoProgressRecord? record = await local.progressFor('333');
      expect(record, isNotNull);
      expect(record!.episodeIndex, 5);
      expect(record.finished, isTrue);
      expect(await local.progressFor('999'), isNull);
    });

    test('预约记录增删', () async {
      final HongguoRecordStore local = hongguoLocalRecords();
      await local.addReservation(
          const HongguoReservationRecord(seriesId: '444', title: '想看剧'));
      expect((await local.reservations()).length, 1);
      await local.removeReservation('444');
      expect(await local.reservations(), isEmpty);
    });
  });

  group('退避与轮换', () {
    test('App 重试延迟递增', () {
      expect(hongguoAppRetryDelay(1), const Duration(seconds: 1));
      expect(hongguoAppRetryDelay(2), const Duration(seconds: 2));
    });

    test('榜单重试延迟为平方退避', () {
      expect(hongguoRankingRetryDelay(1), const Duration(milliseconds: 300));
      expect(hongguoRankingRetryDelay(2), const Duration(milliseconds: 1200));
    });

    test('轮换次数上限为 3', () {
      expect(hongguoShouldRotate(0), isTrue);
      expect(hongguoShouldRotate(2), isTrue);
      expect(hongguoShouldRotate(3), isFalse);
    });

    test('设备号运行时生成 19 位数字', () {
      final String first = newHongguoDeviceId();
      final String second = newHongguoDeviceId();
      expect(RegExp(r'^[1-8][0-9]{18}$').hasMatch(first), isTrue);
      expect(first, isNot(second));
    });

    test('设备状态恢复校验', () {
      expect(HongguoDeviceState.restore(null), isNull);
      expect(
        HongguoDeviceState.restore(<String, dynamic>{
          'version': 1,
          'deviceId': 'abc',
          'installId': '123'
        }),
        isNull,
      );
      final HongguoDeviceState? restored =
          HongguoDeviceState.restore(<String, dynamic>{
        'version': 1,
        'deviceId': '1234567890123456789',
        'installId': '1234567890123456788',
        'registered': true,
      });
      expect(restored, isNotNull);
      expect(restored!.registered, isTrue);
    });

    test('负缓存窗口标记与清除', () {
      final HongguoDeviceState state = HongguoDeviceState();
      expect(state.playerSuspended, isFalse);
      state.markPlayerSuspended();
      expect(state.playerSuspended, isTrue);
      state.clearPlayerSuspended();
      expect(state.playerSuspended, isFalse);
    });

    test('设备注册响应解析', () {
      final ({String deviceId, String installId}) ids =
          parseHongguoDeviceRegisterResponse(
        '{"device_id_str":"1234567890123456789","install_id_str":"1234567890123456788"}',
      );
      expect(ids.deviceId, '1234567890123456789');
      expect(
        () => parseHongguoDeviceRegisterResponse(
            '{"device_id_str":"0","install_id_str":"0"}'),
        throwsFormatException,
      );
    });
  });

  group('模型与解析', () {
    test('剧集解析取 video_data 优先字段', () {
      final HongguoDrama? drama = hongguoDramaFromAny(<String, dynamic>{
        'video_data': <String, dynamic>{
          'series_id_str': '777',
          'series_title': '测试剧',
          'series_cover': 'https://example.com/cover.jpg',
          'episode_cnt': '30',
          'series_status': '1',
          'tags': <String>['重生'],
        },
      }, '真人剧');
      expect(drama, isNotNull);
      expect(drama!.id, 'hongguo:777');
      expect(drama.title, '测试剧');
      expect(drama.remark, '共30集');
      expect(drama.releaseStatus, 'finished');
      expect(drama.tags, <String>['重生']);
      expect(hongguoDramaFromAny(<String, dynamic>{'series_id_str': 'abc'}, ''),
          isNull);
    });

    test('路由数据解析与 loader 查找', () {
      const String html =
          '<script>window._ROUTER_DATA = {"loaderData":{"category_page":{"isSuccess":true,"recommendList":[]}}}</script>';
      final Map<String, dynamic> data = parseHongguoRouterData(html);
      final Map<String, dynamic> page = hongguoRouterLoaderMap(
          data, <String>['category_page', r'category_$']);
      expect(page['isSuccess'], isTrue);
      expect(parseHongguoRouterData('<html></html>'), isEmpty);
    });

    test('分类页解析推进游标', () {
      final HongguoCatalogPage page = parseHongguoCatalogPage(
        <String, dynamic>{
          'data': <String, dynamic>{
            'video_data': <dynamic>[
              <String, dynamic>{
                'video_data': <String, dynamic>{
                  'series_id_str': '1',
                  'series_title': '剧一'
                },
              },
            ],
            'next_offset': '54',
            'has_more': true,
            'session_id': 'sess1',
          },
        },
        const HongguoCatalogCursor(),
        '真人剧',
        pageSignature: (List<String> ids) => 'sig-${ids.join(',')}',
      );
      expect(page.dramas.length, 1);
      expect(page.cursor.offset, 54);
      expect(page.cursor.initialized, isTrue);
      expect(page.cursor.exhausted, isFalse);
      expect(page.cursor.sessionId, 'sess1');
    });

    test('App 详情解析校验分集连续', () {
      final HongguoDetail detail = parseHongguoAppDetail(<String, dynamic>{
        'data': <String, dynamic>{
          'video_data': <String, dynamic>{
            'series_id_str': '5',
            'series_title': '详情剧',
            'episode_cnt': '2',
            'video_list': <dynamic>[
              <String, dynamic>{'vid': '101', 'vid_index': '1'},
              <String, dynamic>{'vid': '102', 'vid_index': '2'},
            ],
          },
        },
      }, '5');
      expect(detail.episodes.length, 2);
      expect(detail.episodes[1].title, '第2集');
      expect(
        () => parseHongguoAppDetail(<String, dynamic>{
          'data': <String, dynamic>{
            'video_data': <String, dynamic>{'series_id_str': '6'},
          },
        }, '5'),
        throwsFormatException,
      );
    });

    test('媒体选择跳过 bytevc2、优先高清 h264', () {
      final HongguoMedia media = selectHongguoAppMedia(
        <String, dynamic>{
          'video_duration': '60',
          'video_list': <dynamic>[
            <String, dynamic>{
              'video_meta': <String, dynamic>{
                'codec_type': 'bytevc2',
                'vheight': '1080'
              },
              'main_url': 'https://example.com/bytevc2.mp4',
            },
            <String, dynamic>{
              'video_meta': <String, dynamic>{
                'codec_type': 'h264',
                'vheight': '480'
              },
              'main_url': 'https://example.com/480.mp4',
            },
            <String, dynamic>{
              'video_meta': <String, dynamic>{
                'codec_type': 'h264',
                'vheight': '720'
              },
              'main_url': 'https://example.com/720.mp4',
            },
          ],
        },
        isMediaUrl: hongguoIsMediaUrl,
        tryBase64Decode: hongguoTryBase64DecodeText,
        contentKey: (_) => throw StateError('不应调用密钥解码'),
      );
      expect(media.url, 'https://example.com/720.mp4');
      expect(media.quality, 720);
      expect(media.variants.length, 2);
    });

    test('弹幕解析过滤异集与越界条目并展开表情', () {
      final HongguoDanmakuPage page = parseHongguoDanmaku(
        <String, dynamic>{
          'data': <String, dynamic>{
            'data_list': <dynamic>[
              <String, dynamic>{
                'comment': <String, dynamic>{
                  'comment_id': 'c1',
                  'common': <String, dynamic>{
                    'group_id': '101',
                    'status': '1',
                    'content': <String, dynamic>{'text': '[笑哭]好看'},
                  },
                  'expand': <String, dynamic>{'offset_time': '5000'},
                },
              },
              <String, dynamic>{
                'comment': <String, dynamic>{
                  'comment_id': 'c2',
                  'common': <String, dynamic>{
                    'group_id': '999',
                    'status': '1',
                    'content': <String, dynamic>{'text': '异集'},
                  },
                  'expand': <String, dynamic>{'offset_time': '6000'},
                },
              },
            ],
            'extra': <String, dynamic>{'next_query_danmaku_list_time': '30000'},
            'common_list_info': <String, dynamic>{
              'cursor': '{"danmaku_count": 42}'
            },
          },
        },
        '101',
        0,
        60000,
      );
      expect(page.items.length, 1);
      expect(page.items.first.text, '😂好看');
      expect(page.total, 42);
      expect(page.nextMs, 30000);
    });

    test('表情展开未知短码原样保留', () {
      expect(expandHongguoDanmakuEmoji('[未知]文本'), '[未知]文本');
      expect(expandHongguoDanmakuEmoji('无短码'), '无短码');
    });

    test('搜索词校验与标题排序', () {
      expect(validateHongguoSearchKeyword('  神瞳  '), '神瞳');
      expect(() => validateHongguoSearchKeyword(''), throwsFormatException);
      expect(hongguoTitleSearchRank('神瞳', '神瞳'), 0);
      expect(hongguoTitleSearchRank('神瞳传说', '神瞳'), 1);
      expect(hongguoTitleSearchRank('我的神瞳', '神瞳'), 2);
      expect(hongguoTitleSearchRank('无关', '神瞳'), 4);
    });

    test('多季分组按季排序', () {
      const HongguoDrama anchor =
          HongguoDrama(id: 'hongguo:1', sourceId: '1', title: '长剧第1季');
      final List<HongguoSeriesEntry> entries =
          hongguoSeriesEntries(anchor, <HongguoDrama>[
        const HongguoDrama(id: 'hongguo:2', sourceId: '2', title: '长剧第3季'),
        const HongguoDrama(id: 'hongguo:3', sourceId: '3', title: '长剧第二季'),
        const HongguoDrama(id: 'hongguo:4', sourceId: '4', title: '别剧第1季'),
      ]);
      expect(entries.map((HongguoSeriesEntry entry) => entry.season),
          <int>[1, 2, 3]);
      expect(entries[1].label, '第 2 季');
    });

    test('榜单路由数据解析', () {
      const String body =
          '<script>window._ROUTER_DATA = {"loaderData":{"rank_hot-drama/page":'
          '{"rankKey":"hongguo","pageNum":"1","content":{"isSuccess":true,'
          '"rankList":[{"seriesId":"9","rank":1,"title":"榜一","heatText":"100万热度"}],'
          '"pagination":{"pageNum":1,"totalPages":3}}}}}</script>';
      final HongguoRankingPage page =
          parseHongguoRanking(body, hongguoRankingBoards.first, 1);
      expect(page.items.length, 1);
      expect(page.items.first.rank, 1);
      expect(page.items.first.drama.title, '榜一');
      expect(page.hasMore, isTrue);
      expect(page.totalPages, 3);
    });
  });

  group('编解码', () {
    test('备用响应明文原样返回', () {
      final List<int> decoded =
          decodeHongguoPlaybackResponse('{"key_urls":[]}');
      expect(utf8.decode(decoded), '{"key_urls":[]}');
    });

    test('备用响应坏密钥段抛错', () {
      expect(() => decodeHongguoPlaybackResponse('v2.ab.cd'),
          throwsFormatException);
    });

    test('内容密钥坏输入抛错', () {
      expect(() => hongguoContentKey('!!!'), throwsFormatException);
      expect(() => hongguoContentKey('aGVsbG8='), throwsFormatException);
    });

    test('媒体地址校验', () {
      expect(hongguoIsMediaUrl('https://example.com/a.mp4'), isTrue);
      expect(hongguoIsMediaUrl('ftp://example.com/a.mp4'), isFalse);
      expect(hongguoIsMediaUrl(''), isFalse);
    });
  });

  group('播放策略', () {
    test('清晰度标签与编解码过滤', () {
      expect(hongguoQualityLabel(720), '720p');
      expect(hongguoQualityLabel(0), '自动');
      expect(hongguoIsIncompatibleCodec('bytevc2', ''), isTrue);
      expect(hongguoIsIncompatibleCodec('h264', ''), isFalse);
      expect(hongguoIsPreferredCodec('avc1'), isTrue);
    });

    test('下一集与跨季判定', () {
      const List<HongguoEpisode> episodes = <HongguoEpisode>[
        HongguoEpisode(id: 'a', videoId: '1', index: 1, title: '第1集'),
        HongguoEpisode(id: 'b', videoId: '2', index: 2, title: '第2集'),
      ];
      expect(hongguoNextEpisode(episodes, 1)?.videoId, '2');
      expect(hongguoNextEpisode(episodes, 2), isNull);
      const HongguoDrama current =
          HongguoDrama(id: 'hongguo:1', sourceId: '1', title: '连播剧第1季');
      final HongguoDrama? next =
          hongguoNextSeasonDrama(current, 1, <HongguoDrama>[
        const HongguoDrama(id: 'hongguo:2', sourceId: '2', title: '连播剧第2季'),
      ]);
      expect(next?.sourceId, '2');
      expect(
          hongguoNextSeasonDrama(current, 2, const <HongguoDrama>[]), isNull);
    });
  });

  group('假传输客户端', () {
    test('App 请求成功返回解析后数据（假签名）', () async {
      final HongguoAppClient client = HongguoAppClient(
        transport: _FakeTransport(
          postHandler: (_) => const HongguoHttpResponse(
              statusCode: 200, body: '{"code":"0","data":{}}'),
        ),
        signer: _FakeSigner(),
      );
      final Map<String, dynamic> result = await client.appRequest(
        method: 'POST',
        path: '/reading/distribution/category/landpage/v/',
        payload: <String, dynamic>{},
      );
      expect(result['code'], '0');
    });

    test('App 玩家接口空响应触发负缓存窗口', () async {
      final HongguoAppClient client = HongguoAppClient(
        transport: _FakeTransport(
          postHandler: (_) =>
              const HongguoHttpResponse(statusCode: 200, body: ''),
        ),
        signer: _FakeSigner(),
      );
      await expectLater(
        client.appRequest(
            method: 'POST', path: '/novel/player/video_detail/v1/'),
        throwsA(isA<HongguoAppEmptyBody>()),
      );
      expect(client.deviceState.playerSuspended, isTrue);
    });

    test('网页兜底：游客会话 + fallback 返回地址', () async {
      final HongguoWebClient client = HongguoWebClient(
        transport: _FakeTransport(
          getHandler: (Uri uri) {
            if (uri.path == '/') {
              return const HongguoHttpResponse(
                statusCode: 200,
                body: '<html></html>',
                cookies: <String, String>{'ttwid': 'fake-ttwid'},
              );
            }
            return const HongguoHttpResponse(statusCode: 404, body: '');
          },
          postHandler: (_) => const HongguoHttpResponse(
            statusCode: 200,
            body: '{"main_url":"https://example.com/play.mp4"}',
          ),
        ),
      );
      final HongguoMedia media = await client.resolveWebFallback('123', '456');
      expect(media.url, 'https://example.com/play.mp4');
      expect(media.referer, 'https://hongguoduanju.com/');
    });

    test('网页兜底 403 时报未开放', () async {
      final HongguoWebClient client = HongguoWebClient(
        transport: _FakeTransport(
          getHandler: (_) => const HongguoHttpResponse(
            statusCode: 200,
            body: '<html></html>',
            cookies: <String, String>{'ttwid': 'fake-ttwid'},
          ),
          postHandler: (_) =>
              const HongguoHttpResponse(statusCode: 403, body: ''),
          headHandler: (_) =>
              const HongguoHttpResponse(statusCode: 404, body: ''),
        ),
      );
      await expectLater(
        client.resolveWebFallback('123', '456'),
        throwsA(isA<HongguoWebException>()),
      );
    });

    test('线路顺序默认大陆优先、海外优先可调', () {
      expect(hongguoRouteOrder().first, HongguoRoute.appMainland);
      expect(hongguoRouteOrder(oversea: true).first, HongguoRoute.appOversea);
      expect(hongguoRouteOrder().length, 6);
    });
  });
}
