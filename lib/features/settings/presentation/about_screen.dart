/// About screen —— application info, licenses, repository and update entry.
library;

import 'package:material_ui/material_ui.dart';
import 'package:wxyy/generated/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/update/update_manager.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_glass_bar.dart';

import './widgets/settings_widgets.dart';
import './settings_announcements_screen.dart';
import './settings_update_screen.dart';

/// 致谢条目数据模型（文件作用域）。
class _AcknowledgementCredit {
  final String name;
  final String desc;
  final String url;
  const _AcknowledgementCredit({
    required this.name,
    required this.desc,
    required this.url,
  });
}

/// 致谢弹窗中的单条署名卡片。
class _AcknowledgementCard extends StatelessWidget {
  final _AcknowledgementCredit credit;
  final AppLocalizations l10n;
  const _AcknowledgementCard({
    required this.credit,
    required this.l10n,
  });

  Future<void> _open() async {
    final Uri uri = Uri.parse(credit.url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            credit.name,
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppTokens.spaceXs),
          Text(credit.desc, style: textTheme.bodySmall),
          const SizedBox(height: AppTokens.spaceXs),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _open,
              child: Text(l10n.acknowledgementsViewProject),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  PackageInfo? _packageInfo;
  bool _downloadCompleteNotified = false;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
    // 更新对话框已关闭时，后台下载完成/失败经此回调弹提示（保证静默/关框下载可感知）。
    UpdateManager.instance.addListener(_onUpdateManagerChanged);
  }

  @override
  void dispose() {
    UpdateManager.instance.removeListener(_onUpdateManagerChanged);
    super.dispose();
  }

  void _onUpdateManagerChanged() {
    final m = UpdateManager.instance;
    if (!mounted) return;
    if (m.status == UpdateStatus.done && !_downloadCompleteNotified) {
      _downloadCompleteNotified = true;
      final String name = m.progress.fileName;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name 下载完成')),
      );
    } else if (m.status == UpdateStatus.failed && !_downloadCompleteNotified) {
      _downloadCompleteNotified = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m.lastError ?? '下载失败')),
      );
    }
  }

  Future<void> _loadPackageInfo() async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _packageInfo = info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String versionText = _packageInfo == null
        ? ''
        : '${_packageInfo!.version}+${_packageInfo!.buildNumber}';

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aboutAppTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: ListView(
        padding: context.pageInset(AppTokens.spaceLg),
        children: <Widget>[
          // ── App identity block ──
          Center(
            child: Column(
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusLg),
                  child: Image.asset(
                    'assets/icon/icon.png',
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                Text(
                  '万象影院',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXs),
                if (versionText.isNotEmpty)
                  Text(
                    versionText,
                    style: textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: AppTokens.spaceXl),

          // ── 条目统一为独立描边小卡──
          SettingsGroup(
            header: l10n.aboutAppTitle,
            children: <Widget>[
              SettingsTile(
                icon: Icons.campaign_rounded,
                title: l10n.appAnnouncement,
                subtitle: l10n.announcementSettingsDesc,
                onTap: () => _openAnnouncements(),
              ),
              SettingsTile(
                icon: Icons.info_rounded,
                title: l10n.aboutApp,
                subtitle: l10n.aboutDescription,
              ),
              SettingsTile(
                icon: Icons.description_rounded,
                title: l10n.openSourceLicenses,
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: '万象影院',
                  applicationVersion: versionText,
                  applicationIcon: const SizedBox(
                    width: 48,
                    height: 48,
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.all(Radius.circular(AppTokens.radiusMd)),
                      child: Image(
                        image: AssetImage('assets/icon/icon.png'),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
              SettingsTile(
                icon: Icons.inventory_2_rounded,
                title: l10n.thirdPartyLibraries,
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: '万象影院',
                  applicationVersion: versionText,
                ),
              ),
              SettingsTile(
                icon: Icons.favorite_rounded,
                title: l10n.acknowledgements,
                onTap: () => _showAcknowledgements(l10n),
              ),
              SettingsTile(
                icon: Icons.system_update_alt_rounded,
                title: l10n.updateSettings,
                subtitle: l10n.updateSettingsDesc,
                onTap: () => _openUpdateSettings(),
              ),
            ],
          ),

          const SizedBox(height: AppTokens.spaceLg),
        ],
      ),
    );
  }

  /// 打开软件公告页（历史公告随时回看）。
  void _openAnnouncements() {
    AppHaptics.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsAnnouncementsScreen(),
      ),
    );
  }

  /// 打开统一更新设置页（含升级通道、自动下载、镜像与检查更新）。
  void _openUpdateSettings() {
    AppHaptics.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsUpdateScreen(),
      ),
    );
  }

  Future<void> _showAcknowledgements(AppLocalizations l10n) async {
    AppHaptics.selectionClick();
    final List<_AcknowledgementCredit> credits = <_AcknowledgementCredit>[
      _AcknowledgementCredit(
        name: 'Legado',
        desc: l10n.acknowledgementsLegado,
        url: 'https://github.com/gedoor/legado',
      ),
      _AcknowledgementCredit(
        name: 'Mihon',
        desc: l10n.acknowledgementsMihon,
        url: 'https://github.com/mihonapp/mihon',
      ),
      _AcknowledgementCredit(
        name: 'RSSHub',
        desc: l10n.acknowledgementsRssHub,
        url: 'https://github.com/DIYgod/RSSHub',
      ),
      _AcknowledgementCredit(
        name: 'wenyi',
        desc: l10n.acknowledgementsWenyi,
        url: 'https://github.com/BigDawnGhost/wenyi',
      ),
      _AcknowledgementCredit(
        name: 'Anime4K',
        desc: l10n.acknowledgementsAnime4K,
        url: 'https://github.com/bloc97/Anime4K',
      ),
    ];
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AppAlertDialog(
        title: Text(l10n.acknowledgements),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ...credits.map(
                (c) => _AcknowledgementCard(credit: c, l10n: l10n),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              Text(
                l10n.acknowledgementsMoreLibs,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }
}
