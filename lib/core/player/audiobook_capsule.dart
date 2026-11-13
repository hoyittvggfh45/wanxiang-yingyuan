/// 听书悬浮胶囊（灵动岛）：应用切后台且听书在播时，在桌面显示的迷你播放条。
///
/// 形态：原生悬浮窗（WindowManager overlay），封面 + 标题 + 播放/暂停 + 关闭；
/// 点胶囊主体回听书页；回前台自动收起；暂停/播完/退出听书时消失。
///
/// 权限：Android 悬浮窗权限（SYSTEM_ALERT_WINDOW）按系统规矩申请——Dart 侧
/// 经原生通道查 `Settings.canDrawOverlays`、跳系统设置页授权。拿不到权限时
/// 诚实降级：只留通知栏/锁屏控制，绝不假装胶囊存在。
///
/// 平台：仅 Android。鸿蒙 NEXT + 卓易通容器上悬浮窗能不能用无法在本机验，
/// 须用户手机实测（未验）。iOS/桌面/Web 上全部方法为无操作，返回 false。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/platform_service.dart';

/// 胶囊上显示的一条听书状态（标题/作品/封面/播放态）。
class AudiobookCapsuleInfo {
  const AudiobookCapsuleInfo({
    required this.title,
    required this.artist,
    this.artUrl,
    required this.playing,
  });

  /// 章节标题。
  final String title;

  /// 作品名。
  final String artist;

  /// 封面地址（可为空；原生侧加载失败显示占位图）。
  final String? artUrl;

  /// 是否在播（决定胶囊上显示暂停还是播放图标）。
  final bool playing;

  AudiobookCapsuleInfo copyWith({
    String? title,
    String? artist,
    String? artUrl,
    bool? playing,
  }) {
    return AudiobookCapsuleInfo(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      artUrl: artUrl ?? this.artUrl,
      playing: playing ?? this.playing,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudiobookCapsuleInfo &&
      other.title == title &&
      other.artist == artist &&
      other.artUrl == artUrl &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(title, artist, artUrl, playing);
}

/// 胶囊显隐的纯决策（可单测，不碰平台通道）。
class AudiobookCapsulePolicy {
  const AudiobookCapsulePolicy._();

  /// 是否应显示胶囊：仅当应用已切后台、在播、有悬浮窗权限且平台支持时。
  static bool shouldShow({
    required bool backgrounded,
    required bool playing,
    required bool permitted,
    required bool supported,
  }) {
    return backgrounded && playing && permitted && supported;
  }

  /// 显示中的胶囊是否需要刷新内容（章节/播放态变化时）。
  static bool needsUpdate(
    AudiobookCapsuleInfo? shown,
    AudiobookCapsuleInfo current,
  ) {
    return shown != null && shown != current;
  }
}

/// 胶囊原生通道事件（原生胶囊按钮点按回传）。
enum AudiobookCapsuleEvent {
  /// 点播放/暂停按钮。
  playPause,

  /// 点关闭按钮（Dart 侧暂停播放并收起胶囊）。
  close,

  /// 点胶囊主体（原生已把应用带回前台；Dart 侧仅作收起兜底）。
  tap,
}

/// 听书胶囊桥：Dart 侧唯一入口，原生实现见
/// `android/.../AudiobookCapsuleBridge.kt`。
class AudiobookCapsuleBridge {
  AudiobookCapsuleBridge._();

  static final AudiobookCapsuleBridge instance = AudiobookCapsuleBridge._();

  static const MethodChannel _channel =
      MethodChannel('wxyy/audiobook_capsule');
  static const EventChannel _eventChannel =
      EventChannel('wxyy/audiobook_capsule_events');

  /// 当前胶囊是否已显示（Dart 侧记账；原生失败时以返回值为准）。
  bool _visible = false;

  /// 当前显示中的胶囊内容（供 needsUpdate 判定）。
  AudiobookCapsuleInfo? _shownInfo;

  /// 权限引导 SnackBar 本次启动是否已展示过（只打扰用户一次）。
  bool _permissionNudgeShown = false;

  bool get isVisible => _visible;
  AudiobookCapsuleInfo? get shownInfo => _shownInfo;
  bool get permissionNudgeShown => _permissionNudgeShown;

  void markPermissionNudgeShown() => _permissionNudgeShown = true;

  /// 仅 Android 支持悬浮窗胶囊（鸿蒙原生 Flutter-OH 不走此通道）。
  bool get supported => PlatformService.instance.isAndroid;

  /// 原生胶囊事件流（play_pause / close / tap）。非 Android 平台为空流。
  Stream<AudiobookCapsuleEvent> get events {
    if (!supported) return const Stream<AudiobookCapsuleEvent>.empty();
    return _eventChannel.receiveBroadcastStream().map((Object? event) {
      switch (event) {
        case 'play_pause':
          return AudiobookCapsuleEvent.playPause;
        case 'close':
          return AudiobookCapsuleEvent.close;
        case 'tap':
          return AudiobookCapsuleEvent.tap;
        default:
          return AudiobookCapsuleEvent.tap;
      }
    });
  }

  /// 是否已有悬浮窗权限。通道失败一律按无权限处理（诚实降级）。
  Future<bool> hasPermission() async {
    if (!supported) return false;
    try {
      final bool? granted =
          await _channel.invokeMethod<bool>('hasPermission');
      return granted ?? false;
    } on Object {
      return false;
    }
  }

  /// 跳系统设置页申请悬浮窗权限（须在前台调用，后台拉起会被系统拦截）。
  /// 返回调用是否发出（不代表用户已授权，授权状态以后续 hasPermission 为准）。
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      final bool? sent =
          await _channel.invokeMethod<bool>('requestPermission');
      return sent ?? false;
    } on Object {
      return false;
    }
  }

  /// 显示胶囊（已显示时改为更新内容）。无权限/不支持时返回 false。
  Future<bool> show(AudiobookCapsuleInfo info) async {
    if (!supported) return false;
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        _visible ? 'update' : 'show',
        <String, Object?>{
          'title': info.title,
          'artist': info.artist,
          'artUrl': info.artUrl,
          'playing': info.playing,
        },
      );
      _visible = ok ?? false;
      if (_visible) _shownInfo = info;
      return _visible;
    } on Object {
      _visible = false;
      return false;
    }
  }

  /// 更新显示中的胶囊内容（未显示时等价于 show）。
  Future<bool> update(AudiobookCapsuleInfo info) => show(info);

  /// 收起胶囊（幂等）。
  Future<void> hide() async {
    if (!_visible || !supported) {
      _visible = false;
      _shownInfo = null;
      return;
    }
    try {
      await _channel.invokeMethod<void>('hide');
    } on Object {
      // 收起失败不抛错：记账清零，避免 Dart 侧误以为还在显示。
    }
    _visible = false;
    _shownInfo = null;
  }
}
