import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/audiobook/home_destination_order.dart';
import 'package:wxyy/core/settings/general_settings.dart';
import 'package:wxyy/core/widgets/library_shell.dart';

/// 分叉门禁静态检查（源码级，不跑界面）：导航顺序、登录类删除干净、保留项
/// 存在、启动不挡路。界面行为仍需手机实测。
void main() {
  group('导航顺序（用户 2026-11-13 定）', () {
    test('目的地顺序：浏览/小说/媒体/漫画/听书/直播/设置', () {
      expect(homeDestinationKeys, <String>[
        'browse',
        'novel',
        'media',
        'comic',
        'audiobook',
        'live',
        'settings',
      ]);
      expect(audiobookDestinationIndex, 4);
      expect(liveDestinationIndex, 5);
    });

    test('启动 Tab 映射：前 4 个对下标，设置恒取最后一页', () {
      expect(pageIndexForLaunchTab(LaunchTab.browse, pageCount: 7), 0);
      expect(pageIndexForLaunchTab(LaunchTab.comic, pageCount: 7), 3);
      expect(pageIndexForLaunchTab(LaunchTab.settings, pageCount: 7), 6);
    });

    test('媒体区顶栏无直播页签（直播已是独立导航目的地）', () {
      expect(LibraryTopTab.values, <LibraryTopTab>[
        LibraryTopTab.library,
        LibraryTopTab.online,
        LibraryTopTab.subscribe,
        LibraryTopTab.sources,
      ]);
      final mediaHome =
          File('lib/features/media/presentation/media_home_screen.dart')
              .readAsStringSync();
      expect(mediaHome.contains('liveBody'), isFalse);
    });

    test('首页组装直播页时包 Scaffold（LiveScreen 自身无 Scaffold）', () {
      final homeScreen =
          File('lib/features/home/presentation/home_screen.dart')
              .readAsStringSync();
      expect(homeScreen, contains('_LiveTabPage'));
      expect(homeScreen, contains('const LiveScreen()'));
      expect(homeScreen, contains('navLive'));
      expect(homeScreen, contains('navAudiobook'));
    });
  });

  group('登录类删除干净（用户 23:56 令 + 00:11 云同步令）', () {
    final deletedSymbols = <String>[
      'BangumiAuth',
      'BangumiClient',
      'BangumiSyncService',
      'SourceAuthManager',
      'SourceKeyStore',
      'MediaServerPlayback',
      'MediaServerPlaybackSession',
      'DandanplayAuth',
      'CloudSyncService',
      'AutoSyncScheduler',
      'SettingsCloudSyncScreen',
      'SettingsDandanplayAccountScreen',
      'SettingsBangumiScreen',
      '_showDanmakuInput',
    ];

    test('lib/ 内无指向已删登录/同步类的引用（生成文件除外）', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains('/generated/')) continue;
        final text = entity.readAsStringSync();
        for (final name in deletedSymbols) {
          if (text.contains(name)) {
            offenders.add('${entity.path}: $name');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('已删登录/同步文件不存在', () {
      final deletedFiles = <String>[
        'lib/core/auth/source_auth_manager.dart',
        'lib/core/auth/source_auth_header.dart',
        'lib/core/auth/source_key_store.dart',
        'lib/core/danmaku/dandanplay_auth.dart',
        'lib/core/services/cloud_sync_service.dart',
        'lib/core/services/auto_sync_scheduler.dart',
        'lib/core/services/media_server/media_server_auth.dart',
        'lib/core/services/media_server/media_server_client.dart',
        'lib/features/settings/presentation/settings_cloud_sync_screen.dart',
        'lib/features/settings/presentation/settings_dandanplay_account_screen.dart',
        'lib/features/player/presentation/video_player_danmaku_input.dart',
      ];
      for (final path in deletedFiles) {
        expect(File(path).existsSync(), isFalse, reason: path);
      }
    });

    test('ECH 通用网络能力保留（不是登录功能）', () {
      expect(
        File('lib/core/services/bangumi/bangumi_ech_proxy.dart').existsSync(),
        isTrue,
      );
    });
  });

  group('保留项存在（用户 1 和 2 口径）', () {
    test('引导页、关于页、更新页、公告页文件存在', () {
      for (final path in <String>[
        'lib/features/onboarding/presentation/onboarding_screen.dart',
        'lib/features/settings/presentation/about_screen.dart',
        'lib/features/settings/presentation/settings_update_screen.dart',
        'lib/features/settings/presentation/settings_announcements_screen.dart',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    });

    test('应用入口有开屏引导门', () {
      final text = File('lib/app.dart').readAsStringSync();
      expect(text, contains('onboardingCompleted'));
      expect(text, contains('OnboardingScreen'));
    });

    test('引导页无 Bangumi 关联登录步（唯一删除例外）', () {
      final text = File(
        'lib/features/onboarding/presentation/onboarding_screen.dart',
      ).readAsStringSync();
      expect(text.contains('BangumiAuth'), isFalse);
      expect(text.contains('loginWithOAuth'), isFalse);
    });

    test('年龄限制默认开启', () {
      const settings = GeneralSettings();
      expect(settings.ageRestrictionEnabled, isTrue);
    });

    test('站点验证页保留（人机验证不是账号登录）', () {
      expect(
        File(
          'lib/features/verification/presentation/webview_verification_screen.dart',
        ).existsSync(),
        isTrue,
      );
    });

    test('数据页有红果账号行、无云同步与弹幕账号行', () {
      final text = File(
        'lib/features/settings/presentation/settings_data_screen.dart',
      ).readAsStringSync();
      expect(text, contains('_HongguoTile'));
      expect(text.contains('_CloudSyncTile'), isFalse);
      expect(text.contains('_DandanplayTile'), isFalse);
    });

    test('浏览页有海阔小程序卡（原 5 卡键仍在）', () {
      final text = File(
        'lib/features/home/presentation/browse_page.dart',
      ).readAsStringSync();
      expect(text, contains('browseMiniApps'));
      expect(text, contains('MiniAppHomePage'));
      for (final key in <String>[
        'browseLocalFiles',
        'browseNetworkFiles',
        'browseWebScrape',
        'browseRss',
        'browseSniff',
      ]) {
        expect(text, contains(key));
      }
    });
  });

  group('启动不挡路（源码级）', () {
    test('启动页有总超时与分步守卫', () {
      final text = File('lib/features/splash/splash_screen.dart')
          .readAsStringSync();
      expect(text, contains('_guarded'));
      expect(text, contains('45'));
      expect(text, contains('TimeoutException'));
    });

    test('启动链上无已删登录/同步初始化', () {
      final text = File('lib/features/splash/splash_screen.dart')
          .readAsStringSync();
      for (final name in <String>[
        'CloudSyncService',
        'BangumiAuth',
        'BangumiSyncService',
        'MediaServerAuth',
        'SourceAuthManager',
        'AutoSyncScheduler',
      ]) {
        expect(text.contains(name), isFalse, reason: name);
      }
    });

    test('崩溃日志写外部目录', () {
      final text = File('lib/core/debug/crash_log.dart').readAsStringSync();
      expect(text, contains('crash.log'));
    });
  });
}
