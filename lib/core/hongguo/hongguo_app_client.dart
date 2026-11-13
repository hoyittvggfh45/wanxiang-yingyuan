/// 红果 App 接口客户端（fqnovel.com）。
///
/// 移植自火蚁TV Go 核 `provider_hongguo_app.go`（请求流/重试/负缓存）、
/// `provider_hongguo_catalog.go`（分类）、`provider_hongguo_detail.go`
/// （详情）、`provider_hongguo_recommendations.go`（推荐）、
/// `provider_hongguo_native_media.go`（取流）、`provider_hongguo_routes.go`
/// （六线路与批量取流）、`ui_playback_danmaku.go`（弹幕）、
/// `provider_hongguo_playback.go`（备用接口）与
/// `provider_hongguo_device.go`（设备注册调用）。
///
/// 签名缺项：请求流在发请求前调用 [HongguoRequestSigner]，默认签名器
/// 抛 [HongguoSigningUnavailable]，因此全部 App 接口调用都会以签名缺项
/// 失败并诚实上报，绝不以无签名请求冒充。查询参数构造、请求体构造、响
/// 应解析、轮换/退避/负缓存逻辑已全部移植，签名补齐后即可接通。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'hongguo_device.dart';
import 'hongguo_http.dart';
import 'hongguo_models.dart';
import 'hongguo_playback_codec.dart';
import 'hongguo_signing.dart';

/// App 接口大陆线与海外线。
const String hongguoAppBaseUrl = 'https://api5-normal-sinfonlineb.fqnovel.com';
const String hongguoAppOverseaBaseUrl =
    'https://api5-normal-sinfonlinea.fqnovel.com';

/// App 接口 User-Agent：通用运行时值，不照搬来源里的固定机型指纹。
const String hongguoAppUserAgent =
    'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; Android Device)';

/// 备用播放接口（对应 Go `hongguoPlaybackAPI`）。
const String hongguoPlaybackApiUrl =
    'https://djapi.999888456.xyz/api/hongguo/play';

/// App 请求的通用查询参数（对应 Go `hongguoAppQuery`）。
Map<String, String> hongguoAppQuery(String deviceId, String installId) =>
    <String, String>{
      'aid': '8662',
      'app_name': 'novelread',
      'version_code': '73532',
      'version_name': '7.3.5.32',
      'manifest_version_code': '73532',
      'update_version_code': '73532',
      'channel': 'update_64',
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      'device_type': 'Android Device',
      'device_brand': 'Android',
      'language': 'zh',
      'os_api': '36',
      'os_version': '16',
      'resolution': '1280*2772',
      'dpi': '520',
      'ac': 'wifi',
      'device_id': deviceId,
      'iid': installId,
    };

/// App 分类（对应 Go `hongguoAppGenres`）。
const List<({String key, String scene, String name})> hongguoAppGenres =
    <({String key, String scene, String name})>[
  (key: 'short_play', scene: 'default', name: '真人剧'),
  (key: 'comic_series', scene: 'comic_series', name: '漫剧'),
  (key: 'ai_series', scene: 'ai_series', name: 'AI剧'),
];

/// 推荐流（对应 Go `hongguoRecommendationFeeds`）。
const List<({String key, String tabType, String bottomTab})>
    hongguoRecommendationFeeds =
    <({String key, String tabType, String bottomTab})>[
  (key: 'home_feed', tabType: '16', bottomTab: '7'),
  (key: 'find_drama', tabType: '8', bottomTab: ''),
];

/// 播放线路（对应 Go `hongguoRouteOrder`）。
enum HongguoRoute {
  appMainland('App大陆线'),
  appOversea('App海外线'),
  appBatch('App批量线'),
  webFallback('网页兜底线'),
  webPlayer('网页取流线'),
  playbackApi('备用接口线');

  const HongguoRoute(this.label);

  final String label;
}

/// 线路顺序：海外优先时海外线在前（对应 Go `hongguoRouteOrder`）。
List<HongguoRoute> hongguoRouteOrder({bool oversea = false}) {
  const List<HongguoRoute> mainlandFirst = <HongguoRoute>[
    HongguoRoute.appMainland,
    HongguoRoute.appOversea,
    HongguoRoute.appBatch,
    HongguoRoute.webFallback,
    HongguoRoute.webPlayer,
    HongguoRoute.playbackApi,
  ];
  if (!oversea) return mainlandFirst;
  return <HongguoRoute>[
    HongguoRoute.appOversea,
    HongguoRoute.appMainland,
    HongguoRoute.appBatch,
    HongguoRoute.webFallback,
    HongguoRoute.webPlayer,
    HongguoRoute.playbackApi,
  ];
}

/// App 接口空响应：既是未注册设备号的信号，也是设备被限流的信号。
class HongguoAppEmptyBody implements Exception {
  const HongguoAppEmptyBody([this.message = '红果 App 接口未返回有效数据']);

  final String message;

  @override
  String toString() => message;
}

/// 分类请求体（对应 Go 里的 landpage payload）。
Map<String, dynamic> hongguoCatalogPayload({
  required String scene,
  required String genreKey,
  required int offset,
  required String sessionId,
  required String filterIds,
  List<String> sort = const <String>['online_time'],
}) {
  return <String, dynamic>{
    'req_scene': scene,
    'offset': offset,
    'limit': 54,
    'req_type': 'only_content',
    'need_selector_panel': false,
    'client_req_type': offset > 0 ? 2 : 3,
    'session_id': sessionId,
    'filter_ids': filterIds,
    'select_items': <String, dynamic>{
      'genre': <String>[genreKey],
      'sort': sort,
      'gender': <String>[],
      'category_dim_theme': <String>[],
      'category_dim_role': <String>[],
      'category_dim_epoch': <String>[],
      'online_time': <String>[],
      'creation_status': <String>[],
    },
  };
}

/// 批量取流请求体（对应 Go `hongguoBatchPayload`）。
Map<String, dynamic> hongguoBatchPayload(String videoId) => <String, dynamic>{
      'biz_param': <String, dynamic>{
        'detail_page_version': 0,
        'device_level': 3,
        'disable_digg_stat': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'mixed_video_id_map': <String, dynamic>{
        '1004': <String>[videoId],
      },
    };

/// 弹幕请求体（对应 Go `hongguoDanmaku` 的 body）。
Map<String, dynamic> hongguoDanmakuPayload({
  required String seriesId,
  required String videoId,
  required int startMs,
  required int durationMs,
}) =>
    <String, dynamic>{
      'comment_source': 601,
      'server_channel': 1000,
      'group_id': videoId,
      'group_type': 30,
      'comment_type': 20,
      'sort': 1,
      'count': 90,
      'cursor': '',
      'aid': 8662,
      'compliance_status': 0,
      'business_param': <String, dynamic>{
        'book_id': seriesId,
        'start_offset_time': startMs,
        'playlet_item_duration': durationMs,
        'need_danmaku_guide_type': <int>[1, 3, 4, 2],
      },
    };

class _DanmakuCacheEntry {
  const _DanmakuCacheEntry({required this.page, required this.expiresAt});

  final HongguoDanmakuPage page;
  final DateTime expiresAt;
}

/// 红果 App 接口客户端。
class HongguoAppClient {
  HongguoAppClient({
    HongguoTransport? transport,
    HongguoRequestSigner? signer,
    HongguoDeviceState? deviceState,
  })  : _transport = transport ?? HongguoHttpTransport(),
        _signer = signer ?? const HongguoUnsignedSigner(),
        deviceState = deviceState ?? HongguoDeviceState();

  final HongguoTransport _transport;
  final HongguoRequestSigner _signer;

  /// 设备状态（可持久化恢复，见 [HongguoDeviceState.restore]）。
  final HongguoDeviceState deviceState;

  final Map<String, HongguoDetail> _detailCache = <String, HongguoDetail>{};
  final Map<String, DateTime> _detailExpires = <String, DateTime>{};
  final Map<String, _DanmakuCacheEntry> _danmakuCache =
      <String, _DanmakuCacheEntry>{};

  /// 统一 App 请求：重试最多 3 次、每次递增退避；空响应触发负缓存窗口。
  ///
  /// [comment] 为真时走文字签名分支（弹幕）；bookmall tab 路径不签名。
  Future<Map<String, dynamic>> appRequest({
    required String method,
    required String path,
    Map<String, String> extra = const <String, String>{},
    Object? payload,
    bool oversea = false,
    bool comment = false,
    bool suppressSuspend = false,
  }) async {
    final bool signed = !comment && path != '/reading/bookapi/bookmall/tab/v1/';
    final String base = oversea ? hongguoAppOverseaBaseUrl : hongguoAppBaseUrl;
    final Map<String, String> query =
        hongguoAppQuery(deviceState.deviceId, deviceState.installId);
    query.addAll(extra);
    final List<int>? body =
        payload == null ? null : utf8.encode(jsonEncode(payload));
    Object? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(hongguoAppRetryDelay(attempt));
      }
      final DateTime now = DateTime.now();
      final Uri uri = Uri.parse('$base$path').replace(
        queryParameters: <String, String>{
          ...query,
          '_rticket': now.millisecondsSinceEpoch.toString(),
        },
      );
      final Map<String, String> headers = <String, String>{
        'User-Agent': hongguoAppUserAgent,
        'Accept': 'application/json',
        'X-XS-From-Web': '0',
        'Sdk-Version': '2',
        ...hongguoUnsignedHeaders(now),
      };
      if (comment) {
        headers['Comment-Source'] = '601';
        headers['Server-Channel'] = '1000';
      }
      if (body != null) {
        headers['Content-Type'] = 'application/json; charset=utf-8';
      }
      if (signed || comment) {
        final Map<String, String> signature = _signer.sign(
          rawQuery: uri.query,
          body: body,
          deviceId: deviceState.deviceId,
          aid: '8662',
          now: now,
          comment: comment,
        );
        headers.addAll(signature);
      }
      if (body != null && signed) {
        headers['X-SS-STUB'] = hongguoBodyStub(body);
      }
      final HongguoHttpResponse response;
      if (method == 'POST') {
        response = await _transport
            .post(uri, headers: headers, body: body)
            .timeout(const Duration(seconds: 20));
      } else {
        response = await _transport
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 20));
      }
      if (response.statusCode != 200) {
        lastError =
            HongguoRequestException('红果 App 接口 HTTP ${response.statusCode}');
        if (response.statusCode >= 400 && response.statusCode < 500) {
          throw lastError;
        }
        continue;
      }
      if (response.body.isEmpty) {
        lastError = const HongguoAppEmptyBody();
        if (path.contains('/player/')) {
          if (suppressSuspend) throw lastError;
          deviceState.markPlayerSuspended();
          break;
        }
        continue;
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const HongguoRequestException('红果 App 接口返回格式异常');
      }
      final Map<String, dynamic> result = decoded.cast<String, dynamic>();
      final String code =
          hongguoMapString(result, <String>['code', 'Code', 'status_code']);
      final String baseCode = hongguoMapString(
        hongguoNestedMap(result, <String>['BaseResp']),
        <String>['StatusCode'],
      );
      final String effectiveCode = code.isNotEmpty ? code : baseCode;
      if (effectiveCode.isNotEmpty && effectiveCode != '0') {
        throw HongguoRequestException(
          '红果 App 接口暂不可用（${effectiveCode.length > 20 ? effectiveCode.substring(0, 20) : effectiveCode}）',
        );
      }
      if (path.contains('/player/')) deviceState.clearPlayerSuspended();
      return result;
    }
    throw lastError ?? const HongguoAppEmptyBody();
  }

  /// 设备注册：先查暂停窗口，失败则挂起 10 分钟（对应 Go `ensureHongguoDevice`）。
  Future<void> ensureDevice({String rejected = ''}) async {
    if (rejected.isEmpty && deviceState.registered) return;
    if (rejected.isNotEmpty && rejected != deviceState.deviceId) return;
    if (deviceState.registerPaused) {
      throw const HongguoRequestException('红果设备注册暂不可用');
    }
    try {
      final ({String deviceId, String installId}) ids = await registerDevice();
      deviceState.applyRegistration(ids.deviceId, ids.installId);
    } on Object {
      deviceState.markRegisterPaused();
      rethrow;
    }
  }

  /// 执行一次设备注册请求，返回新设备号/安装号。
  Future<({String deviceId, String installId})> registerDevice() async {
    final Map<String, String> query = hongguoAppQuery('', '')
      ..remove('device_id')
      ..remove('iid')
      ..['req_id'] = hongguoUuidLike();
    final Uri uri = Uri.parse(hongguoDeviceRegisterUrl).replace(
      queryParameters: <String, String>{
        ...query,
        '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    final HongguoHttpResponse response = await _transport
        .post(
          uri,
          headers: <String, String>{
            'User-Agent': hongguoAppUserAgent,
            'Accept': 'application/json',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: utf8.encode(jsonEncode(hongguoDeviceRegisterPayload())),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HongguoRequestException('红果设备注册 HTTP ${response.statusCode}');
    }
    return parseHongguoDeviceRegisterResponse(response.body);
  }

  /// App 详情（5 分钟缓存，对应 Go `hongguoAppDetail`）。
  Future<HongguoDetail> appDetail(String seriesId) async {
    if (!hongguoNumericId.hasMatch(seriesId)) {
      throw const HongguoRequestException('红果剧集 ID 无效');
    }
    final DateTime? expires = _detailExpires[seriesId];
    if (expires != null && DateTime.now().isBefore(expires)) {
      return _detailCache[seriesId]!;
    }
    final Map<String, dynamic> result = await appRequest(
      method: 'POST',
      path: '/novel/player/video_detail/v1/',
      payload: <String, dynamic>{'series_id': seriesId},
    );
    final HongguoDetail entry = parseHongguoAppDetail(result, seriesId);
    if (_detailCache.length >= 128) {
      _detailCache.clear();
      _detailExpires.clear();
    }
    _detailCache[seriesId] = entry;
    _detailExpires[seriesId] = DateTime.now().add(const Duration(minutes: 5));
    return entry;
  }

  /// App 分类页（对应 Go `parseHongguoCatalogPage` 的调用形态）。
  Future<HongguoCatalogPage> appCatalogPage({
    required String genreKey,
    required String scene,
    required String categoryName,
    required HongguoCatalogCursor cursor,
    String filterIds = '',
  }) async {
    final Map<String, dynamic> result = await appRequest(
      method: 'POST',
      path: '/reading/distribution/category/landpage/v/',
      payload: hongguoCatalogPayload(
        scene: scene,
        genreKey: genreKey,
        offset: cursor.offset,
        sessionId: cursor.sessionId,
        filterIds: filterIds,
      ),
    );
    return parseHongguoCatalogPage(result, cursor, categoryName,
        pageSignature: (List<String> ids) {
      return sha256.convert(utf8.encode(ids.join('\n'))).toString();
    });
  }

  /// App 单线取流：设备轮换最多 3 次（对应 Go `resolveHongguoAppMediaLine`）。
  Future<HongguoMedia> appMediaLine(String videoId,
      {bool oversea = false}) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'video_id': videoId,
      'content_type': 1,
      'biz_param': <String, dynamic>{
        'need_all_video_definition': true,
        'video_platform': 3,
      },
    };
    Object? lastError;
    for (int attempt = 0; attempt <= hongguoDeviceRotations; attempt++) {
      if (attempt > 0) {
        await ensureDevice(rejected: deviceState.deviceId);
      }
      try {
        final Map<String, dynamic> result = await appRequest(
          method: 'POST',
          path: '/novel/player/video_model/v1/',
          payload: payload,
          oversea: oversea,
          suppressSuspend: true,
        );
        final Map<String, dynamic> model = _videoModelFrom(result);
        if (model.isEmpty) {
          deviceState.markLimited();
          lastError = const HongguoAppEmptyBody();
          continue;
        }
        deviceState.clearLimited();
        return selectHongguoAppMedia(
          model,
          isMediaUrl: hongguoIsMediaUrl,
          tryBase64Decode: hongguoTryBase64DecodeText,
          contentKey: hongguoContentKey,
        );
      } on HongguoAppEmptyBody catch (error) {
        deviceState.markLimited();
        lastError = error;
      }
    }
    throw lastError ?? const HongguoAppEmptyBody();
  }

  Map<String, dynamic> _videoModelFrom(Map<String, dynamic> result) {
    final Map<String, dynamic> data =
        hongguoNestedMap(result, <String>['data']);
    Map<String, dynamic> model =
        hongguoNestedMap(data, <String>['video_model']);
    final Object? encodedRaw = data['video_model'];
    if (encodedRaw is String && encodedRaw.isNotEmpty) {
      String encoded = encodedRaw;
      final List<int>? decodedBytes = hongguoTryBase64Decode(encoded);
      if (decodedBytes != null && decodedBytes.isNotEmpty) {
        try {
          encoded = utf8.decode(decodedBytes);
        } on Object {
          // 解码失败时按原字符串解析。
        }
      }
      try {
        final Object? decoded = jsonDecode(encoded);
        if (decoded is Map<String, dynamic>) {
          model = decoded;
        } else if (decoded is Map) {
          model = decoded.cast<String, dynamic>();
        }
      } on Object {
        throw const HongguoRequestException('红果 App 播放信息格式异常');
      }
    }
    if (model.isEmpty) {
      final List<dynamic> rows = hongguoAnyList(data['video_list']);
      if (rows.isNotEmpty) {
        model = <String, dynamic>{
          'video_list': data['video_list'],
          'video_duration': data['video_duration'],
          'duration': data['duration'],
        };
      }
    }
    return model;
  }

  /// App 批量取流（对应 Go `resolveHongguoAppBatchMedia`）。
  Future<HongguoMedia> appBatchMedia(String videoId) async {
    if (!hongguoNumericId.hasMatch(videoId)) {
      throw const HongguoRequestException('红果视频 ID 无效');
    }
    await ensureDevice();
    if (deviceState.limited) {
      await ensureDevice(rejected: deviceState.deviceId);
    }
    final Map<String, dynamic> payload = hongguoBatchPayload(videoId);
    try {
      return await _batchEndpoint(
          '/novel/player/multi_video_model/v1/', payload, videoId);
    } on HongguoRequestException catch (error) {
      if (!error.message.contains('110001')) rethrow;
      return _batchEndpoint(
          '/novel/player/multi_video_model/preload/v1/', payload, videoId);
    }
  }

  Future<HongguoMedia> _batchEndpoint(
      String path, Map<String, dynamic> payload, String videoId) async {
    Object? lastError;
    for (int attempt = 0; attempt <= hongguoDeviceRotations; attempt++) {
      if (attempt > 0) {
        await ensureDevice(rejected: deviceState.deviceId);
      }
      try {
        final Map<String, dynamic> result = await appRequest(
          method: 'POST',
          path: path,
          payload: payload,
          suppressSuspend: true,
        );
        final HongguoMedia media = _batchMediaFromResult(result, videoId);
        deviceState.clearLimited();
        return media;
      } on HongguoAppEmptyBody catch (error) {
        deviceState.markLimited();
        lastError = error;
      }
    }
    throw lastError ?? const HongguoAppEmptyBody();
  }

  HongguoMedia _batchMediaFromResult(
      Map<String, dynamic> result, String videoId) {
    final Map<String, dynamic> data =
        hongguoNestedMap(result, <String>['data']);
    final Map<String, dynamic> entry =
        hongguoNestedMap(data, <String>[videoId]);
    if (entry.isEmpty) {
      throw const HongguoRequestException('红果批量接口未返回本集播放信息');
    }
    Map<String, dynamic> model =
        hongguoNestedMap(entry, <String>['video_model']);
    final Object? encodedRaw = entry['video_model'];
    if (encodedRaw is String && encodedRaw.isNotEmpty) {
      String encoded = encodedRaw;
      final List<int>? decodedBytes = hongguoTryBase64Decode(encoded);
      if (decodedBytes != null && decodedBytes.isNotEmpty) {
        try {
          encoded = utf8.decode(decodedBytes);
        } on Object {
          // 解码失败时按原字符串解析。
        }
      }
      try {
        final Object? decoded = jsonDecode(encoded);
        if (decoded is Map<String, dynamic>) {
          model = decoded;
        } else if (decoded is Map) {
          model = decoded.cast<String, dynamic>();
        }
      } on Object {
        throw const HongguoRequestException('红果批量播放信息格式异常');
      }
    }
    if (model.isEmpty) {
      throw const HongguoRequestException('红果批量接口未返回本集播放信息');
    }
    final HongguoMedia media = selectHongguoAppMedia(
      model,
      isMediaUrl: hongguoIsMediaUrl,
      tryBase64Decode: hongguoTryBase64DecodeText,
      contentKey: hongguoContentKey,
    );
    return media.copyWith(videoId: videoId);
  }

  /// 弹幕一页：30 秒窗口、5 分钟缓存（对应 Go `hongguoDanmaku`）。
  Future<HongguoDanmakuPage> danmakuPage({
    required String seriesId,
    required String videoId,
    required int startMs,
    required int durationMs,
  }) async {
    const int maxDurationMs = 24 * 60 * 60 * 1000;
    if (!hongguoNumericId.hasMatch(seriesId) ||
        !hongguoNumericId.hasMatch(videoId) ||
        startMs < 0 ||
        durationMs <= startMs ||
        durationMs > maxDurationMs) {
      throw const HongguoRequestException('弹幕请求参数无效');
    }
    final String key = '$seriesId:$videoId:$startMs:$durationMs';
    final _DanmakuCacheEntry? cached = _danmakuCache[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.page;
    }
    final Map<String, dynamic> result = await appRequest(
      method: 'POST',
      path: '/novel/commentapi/comment/list/$videoId/v1/',
      payload: hongguoDanmakuPayload(
        seriesId: seriesId,
        videoId: videoId,
        startMs: startMs,
        durationMs: durationMs,
      ),
      comment: true,
    );
    final HongguoDanmakuPage page =
        parseHongguoDanmaku(result, videoId, startMs, durationMs);
    if (_danmakuCache.length >= 128) _danmakuCache.clear();
    _danmakuCache[key] = _DanmakuCacheEntry(
      page: page,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
    return page;
  }

  /// 备用播放接口取流（对应 Go `resolveHongguoPlaybackAPI`）。
  Future<HongguoMedia> playbackApiMedia(String seriesId, String videoId) async {
    if (!hongguoNumericId.hasMatch(seriesId) ||
        !hongguoNumericId.hasMatch(videoId)) {
      throw const HongguoRequestException('红果播放请求缺少有效的剧集 ID');
    }
    final String reference =
        base64Encode(utf8.encode(jsonEncode(<String, dynamic>{
      'content_type': 1004,
      'from_video_id': '',
      'series_id': seriesId,
      'vid': videoId,
      'video_platform': 3,
    })));
    final Uri uri = Uri.parse(hongguoPlaybackApiUrl).replace(
      queryParameters: <String, String>{'id': reference},
    );
    String body;
    try {
      final HongguoHttpResponse response =
          await _transport.get(uri, headers: <String, String>{
        'User-Agent': hongguoAppUserAgent,
        'Referer': 'https://hongguoduanju.com/',
      }).timeout(const Duration(seconds: 20));
      body = response.body;
    } on Object catch (error) {
      if (!_transportFailed(error)) rethrow;
      final Uri httpUri =
          Uri.parse(hongguoPlaybackApiUrl.replaceFirst('https://', 'http://'))
              .replace(
        queryParameters: <String, String>{'id': reference},
      );
      final HongguoHttpResponse response =
          await _transport.get(httpUri, headers: <String, String>{
        'User-Agent': hongguoAppUserAgent,
        'Referer': 'https://hongguoduanju.com/',
      }).timeout(const Duration(seconds: 20));
      body = response.body;
    }
    final List<int> decoded = decodeHongguoPlaybackResponse(body);
    final Object? parsed = jsonDecode(utf8.decode(decoded));
    if (parsed is! Map) {
      throw const HongguoRequestException('红果备用播放接口返回了无效数据');
    }
    final Map<String, dynamic> responseMap = parsed.cast<String, dynamic>();
    for (final String flagKey in <String>['parse', 'jx']) {
      final Object? flag = responseMap[flagKey];
      final String flagText = flag == null ? '' : flag.toString().trim();
      if (!<String>['', 'null', 'false', '0', '"0"', '""'].contains(flagText)) {
        throw const HongguoRequestException('红果备用播放接口没有返回直接媒体地址');
      }
    }
    HongguoMedia? selected;
    int bestQuality = -1;
    Object? keyError;
    final List<HongguoMedia> variants = <HongguoMedia>[];
    final Object? keyUrls = responseMap['key_urls'];
    if (keyUrls is List) {
      for (final Object? optionRaw in keyUrls) {
        if (optionRaw is! Map) continue;
        final Map<String, dynamic> option = optionRaw.cast<String, dynamic>();
        final String mediaUrl =
            hongguoMapString(option, <String>['src']).trim();
        if (!hongguoIsMediaUrl(mediaUrl)) continue;
        final String keyId = hongguoMapString(option, <String>['kid']).trim();
        if (!_isValidKeyId(keyId)) {
          keyError = const FormatException('红果媒体密钥标识无效');
          continue;
        }
        List<int> key;
        try {
          key =
              hongguoContentKey(hongguoMapString(option, <String>['spade_a']));
        } on Object catch (error) {
          keyError = error;
          continue;
        }
        final RegExpMatch? digits = RegExp(r'[0-9]+')
            .firstMatch(hongguoMapString(option, <String>['name']));
        final int quality =
            digits == null ? 0 : int.tryParse(digits.group(0)!) ?? 0;
        final HongguoMedia media = HongguoMedia(
          url: mediaUrl,
          referer: 'https://novel.snssdk.com/',
          cencKey: key,
          quality: quality,
        );
        variants.add(media);
        if (selected == null || quality > bestQuality) {
          selected = media;
          bestQuality = quality;
        }
      }
    }
    if (selected != null) {
      return selected.copyWith(variants: variants);
    }
    if (keyError != null) {
      throw HongguoRequestException('红果备用播放接口密钥不可用：$keyError');
    }
    throw const HongguoRequestException(
        '红果备用播放接口未返回该集可用的媒体和密钥，请稍后重试或确认该集是否仍可访问');
  }

  bool _transportFailed(Object error) {
    final String message = error.toString();
    for (final String fragment in <String>[
      'EOF',
      'connection reset',
      'connection refused',
      'empty reply',
      'server closed',
      'TLS handshake',
    ]) {
      if (message.contains(fragment)) return true;
    }
    return false;
  }

  bool _isValidKeyId(String keyId) {
    if (keyId.length != 32) return false;
    return RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(keyId);
  }
}
