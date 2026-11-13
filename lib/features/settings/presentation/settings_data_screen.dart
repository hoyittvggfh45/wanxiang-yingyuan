import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import './widgets/settings_widgets.dart';
import '../../../core/settings/general_settings.dart';
import 'package:wxyy/generated/app_localizations.dart';
import 'package:wxyy/core/navigation/app_page_route.dart';
import '../../stats/presentation/stats_overview_screen.dart';
import '../../manga/presentation/image_favorite_gallery_screen.dart';
import '../../rss/presentation/rss_favorites_screen.dart';
import './settings_categories_screen.dart';
import './settings_download_screen.dart';
import './settings_import_export_screen.dart';
import '../../hongguo/hongguo_account.dart';
import '../../hongguo/hongguo_login_screen.dart';
import '../../../core/widgets/app_glass_bar.dart';

/// 数据与账户汇总页：统计 / 分类 / 下载 / 备份 / 云同步。
///
/// 通用设置项（启动界面 / 日期格式 / 已看阈值 / 记住位置 / 年龄限制）
/// 已迁出至对应分类页（外观与语言 / 播放与阅读 / 隐私与安全），
/// 此处不再承载全局偏好。
///
/// 版面：每行一张独立描边小卡（[SettingsTile]），行间 4px，见。
class SettingsDataScreen extends StatelessWidget {
  const SettingsDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsCatData),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: ListView(
          padding: context.pageInset(AppTokens.spaceLg),
          children: <Widget>[
            SettingsGroup(
              header: l10n.settingsCatData,
              children: <Widget>[
                SettingsTile(
                  icon: Icons.bar_chart_rounded,
                  title: l10n.statsOverviewTitle,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const StatsOverviewScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.folder_rounded,
                  title: l10n.categoriesManageTitle,
                  subtitle: l10n.categoriesManageDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsCategoriesScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.download_rounded,
                  title: l10n.downloadManagementTitle,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsDownloadScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.photo_library_rounded,
                  title: l10n.imageFavoriteGalleryTitle,
                  subtitle: l10n.imageFavoriteGalleryDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const ImageFavoriteGalleryScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.bookmark_rounded,
                  title: l10n.rssFavorites,
                  subtitle: l10n.rssFavoritesDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const RssFavoritesScreen(),
                    ),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              header: l10n.dataImportExport,
              children: <Widget>[
                SettingsTile(
                  icon: Icons.swap_vert_rounded,
                  title: l10n.dataImportExport,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsImportExportScreen(),
                    ),
                  ),
                ),
                _HongguoTile(
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => HongguoLoginScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 红果账号磁贴：显示登录状态，点进红果登录页（纯可选，不 gate 应用）。
class _HongguoTile extends StatelessWidget {
  final VoidCallback onTap;

  const _HongguoTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: ensureHongguoAccountLoaded(),
      builder: (BuildContext ctx, AsyncSnapshot<void> snap) {
        return ValueListenableBuilder<HongguoAccount?>(
          valueListenable: hongguoAccountNotifier,
          builder: (_, HongguoAccount? account, __) {
            final bool loggedIn = account != null && account.loggedIn;
            final String subtitle = loggedIn
                ? <String>[
                    account.displayName,
                    if (account.maskedPhone.isNotEmpty) account.maskedPhone,
                    account.methodLabel,
                  ].join(' · ')
                : '未登录（可选，仅用于红果身份展示）';
            return SettingsTile(
              icon: Icons.account_circle_rounded,
              title: '红果账号',
              subtitle: subtitle,
              onTap: onTap,
            );
          },
        );
      },
    );
  }
}
