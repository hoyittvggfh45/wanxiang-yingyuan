/// 红果取流服务：六线路按序解析，返回首条成功的媒体。
///
/// 移植自火蚁TV Go 核 `provider_hongguo.go`（`resolveHongguoMedia`）与
/// `provider_hongguo_routes.go`（`hongguoRouteOrder` / 单线路解析）。
/// 线路顺序：App大陆线 → App海外线 → App批量线 → 网页兜底线 →
/// 网页取流线 → 备用接口线（海外优先时前两条对调）。
///
/// 当前实际可通的是后三条网页/备用线：前三条 App 线因签名缺项会快速
/// 失败（抛签名缺项），服务层记录失败原因后继续试下一条，绝不把失败
/// 线路的错误吞掉冒充成功。
library;

import 'package:wxyy/core/hongguo/hongguo_app_client.dart';
import 'package:wxyy/core/hongguo/hongguo_models.dart';
import 'package:wxyy/core/hongguo/hongguo_playback_codec.dart';
import 'package:wxyy/core/hongguo/hongguo_signing.dart';
import 'package:wxyy/core/hongguo/hongguo_web_client.dart';

/// 取流结果：媒体 + 命中的线路 + 各线路失败原因（排障用）。
class HongguoResolveResult {
  const HongguoResolveResult({
    required this.media,
    required this.route,
    this.failures = const <HongguoRoute, Object>{},
  });

  final HongguoMedia media;
  final HongguoRoute route;
  final Map<HongguoRoute, Object> failures;
}

class HongguoResolveException implements Exception {
  const HongguoResolveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 红果取流服务。
class HongguoMediaService {
  HongguoMediaService(
      {HongguoAppClient? appClient, HongguoWebClient? webClient})
      : _app = appClient ?? HongguoAppClient(),
        _web = webClient ?? HongguoWebClient();

  final HongguoAppClient _app;
  final HongguoWebClient _web;

  /// 按线路顺序解析，返回首条成功的媒体。
  Future<HongguoResolveResult> resolveMedia({
    required String seriesId,
    required String videoId,
    bool oversea = false,
  }) async {
    if (!hongguoNumericId.hasMatch(seriesId) ||
        !hongguoNumericId.hasMatch(videoId)) {
      throw const HongguoResolveException('红果章节 ID 无效，请重新获取章节');
    }
    // 负缓存窗口内跳过 App 线，直走网页线（对应 Go `resolveHongguoMedia`）。
    final List<HongguoRoute> routes = _app.deviceState.playerSuspended
        ? <HongguoRoute>[
            HongguoRoute.webFallback,
            HongguoRoute.webPlayer,
            HongguoRoute.playbackApi
          ]
        : hongguoRouteOrder(oversea: oversea);
    final Map<HongguoRoute, Object> failures = <HongguoRoute, Object>{};
    for (final HongguoRoute route in routes) {
      try {
        final HongguoMedia media = await resolveRoute(
          seriesId: seriesId,
          videoId: videoId,
          route: route,
        );
        _validateRouteMedia(media, seriesId, videoId);
        return HongguoResolveResult(
            media: media, route: route, failures: failures);
      } on Object catch (error) {
        failures[route] = error;
      }
    }
    final String detail = failures.entries
        .map((MapEntry<HongguoRoute, Object> entry) =>
            '${entry.key.label}失败：${entry.value}')
        .join('；');
    final bool limited = failures.values.any(
      (Object error) =>
          error is HongguoSigningUnavailable ||
          error.toString().contains('限流') ||
          error is HongguoAppEmptyBody,
    );
    throw HongguoResolveException(
      limited ? '$detail；设备或游客会话可能被限流，请稍后重试' : detail,
    );
  }

  /// 解析指定单线路（供线路切换用）。
  Future<HongguoMedia> resolveRoute({
    required String seriesId,
    required String videoId,
    required HongguoRoute route,
  }) async {
    switch (route) {
      case HongguoRoute.appMainland:
        await _app.ensureDevice();
        if (_app.deviceState.limited) {
          await _app.ensureDevice(rejected: _app.deviceState.deviceId);
        }
        return _app.appMediaLine(videoId);
      case HongguoRoute.appOversea:
        await _app.ensureDevice();
        if (_app.deviceState.limited) {
          await _app.ensureDevice(rejected: _app.deviceState.deviceId);
        }
        return _app.appMediaLine(videoId, oversea: true);
      case HongguoRoute.appBatch:
        return _app.appBatchMedia(videoId);
      case HongguoRoute.webFallback:
        return _web.resolveWebFallback(seriesId, videoId);
      case HongguoRoute.webPlayer:
        return _web.resolveWebMedia(seriesId, videoId);
      case HongguoRoute.playbackApi:
        return _app.playbackApiMedia(seriesId, videoId);
    }
  }

  void _validateRouteMedia(
      HongguoMedia media, String seriesId, String videoId) {
    if (!hongguoIsMediaUrl(media.url)) {
      throw const HongguoResolveException('该线路未返回有效的播放地址');
    }
    if (media.seriesId.isNotEmpty && media.seriesId != seriesId) {
      throw const HongguoResolveException('该线路返回的剧集与当前剧集不符');
    }
    if (media.videoId.isNotEmpty && media.videoId != videoId) {
      throw const HongguoResolveException('该线路返回的集数与当前集数不符');
    }
  }
}
