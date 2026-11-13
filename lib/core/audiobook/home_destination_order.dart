/// 首页底部导航的目的地顺序与启动 Tab 映射（纯 Dart，可单元测试）。
///
/// 顺序（用户 2026-11-13 定）：浏览 / 小说 / 媒体 / 漫画 / 听书 / 直播 / 设置。
/// 原有 5 个目的地的相对顺序不动，听书与直播插在设置之前，听书在直播之前。
///
/// 本文件只定义顺序与映射，页面本体仍由 HomeScreen 组装；两者须保持
/// 一致（见 [homeDestinationKeys] 与 HomeScreen `_pages` 的对照注释）。
/// 若主执行人后续在 [LaunchTab] 补 `audiobook` / `live` 枚举值，
/// [pageIndexForLaunchTab] 的穷举 switch 会在 analyze 报错，届时须同步
/// 补分支（新值直接对应其下标，`settings` 仍取最后一页）。
library;

import 'package:wxyy/core/settings/general_settings.dart';

/// 首页目的地键顺序，与 `HomeScreen._pages` 的页面顺序一一对应。
const List<String> homeDestinationKeys = <String>[
  'browse',
  'novel',
  'media',
  'comic',
  'audiobook',
  'live',
  'settings',
];

/// 听书目的地在导航中的下标（漫画之后、直播之前）。
const int audiobookDestinationIndex = 4;

/// 直播目的地在导航中的下标（听书之后、设置之前）。
const int liveDestinationIndex = 5;

/// 启动 Tab → 首页页下标。
///
/// [LaunchTab] 目前只有 5 个值（无听书/直播）：前 4 个与页下标一一对应；
/// `settings` 恒取最后一页（[pageCount] - 1），新增目的地插在设置之前时
/// 存量「启动进设置」仍落到设置页，无需迁移已存的设置值（设置按枚举名
/// 持久化，见 [GeneralSettings]）。
int pageIndexForLaunchTab(LaunchTab tab, {required int pageCount}) {
  return switch (tab) {
    LaunchTab.browse => 0,
    LaunchTab.novel => 1,
    LaunchTab.media => 2,
    LaunchTab.comic => 3,
    LaunchTab.settings => pageCount - 1,
  };
}
