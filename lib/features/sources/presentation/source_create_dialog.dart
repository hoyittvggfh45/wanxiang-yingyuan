/// 手动新建空白源对话框：只填站名、地址、类型。
///
/// 校验走 [buildManualSource]（与导入同一套 [PluginConfig.validate] 口径）：
/// 校验不过在对话框内诚实报错、不关闭、不建源；通过后把构造好的配置
/// 回传给调用方，由调用方经 `SourceRepository.addSource` 注册。
library;

import 'package:material_ui/material_ui.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../manual_source_factory.dart';

/// 源类型中文标签（与源管理分类页签口径一致：小说/媒体/漫画/听书）。
String manualSourceTypeLabel(SourceType type) => switch (type) {
      SourceType.novelSource => '小说',
      SourceType.animeSource => '媒体',
      SourceType.mangaSource => '漫画',
      SourceType.audioSource => '听书',
    };

/// 弹出新建源对话框，返回构造好的空白源配置；取消返回 null。
Future<PluginConfig?> showSourceCreateDialog(
  BuildContext context, {
  required SourceType initialType,
  SourceType? lockedType,
  Set<String> existingIds = const <String>{},
}) {
  return showDialog<PluginConfig>(
    context: context,
    builder: (_) => SourceCreateDialog(
      initialType: initialType,
      lockedType: lockedType,
      existingIds: existingIds,
    ),
  );
}

/// 新建源对话框本体。
class SourceCreateDialog extends StatefulWidget {
  /// 默认选中的类型（总管理按当前分类页签传入）。
  final SourceType initialType;

  /// 锁定的类型（分区源管理传入本区类型时，类型不可改）。
  final SourceType? lockedType;

  /// 已有源 id 集合，用于派生不冲突的新 id。
  final Set<String> existingIds;

  const SourceCreateDialog({
    super.key,
    required this.initialType,
    this.lockedType,
    this.existingIds = const <String>{},
  });

  @override
  State<SourceCreateDialog> createState() => _SourceCreateDialogState();
}

class _SourceCreateDialogState extends State<SourceCreateDialog> {
  late SourceType _type = widget.lockedType ?? widget.initialType;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  void _submit() {
    final result = buildManualSource(
      name: _nameController.text,
      baseUrl: _urlController.text,
      type: _type,
      existingIds: widget.existingIds,
    );
    if (!result.isValid || result.config == null) {
      setState(() => _error = result.errors.join('\n'));
      return;
    }
    Navigator.of(context).pop(result.config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppAlertDialog(
      title: const Text('新建空白源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '只填站名、地址、类型即可建源；规则与分类建好后在编辑页补。空白源没有解析规则，浏览时没有内容。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              key: const ValueKey<String>('create-source-name'),
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '站名',
                hintText: '例如：示例站点',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _clearError(),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              key: const ValueKey<String>('create-source-url'),
              controller: _urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '站点地址',
                hintText: 'https://example.com',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _clearError(),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Text('类型', style: theme.textTheme.labelMedium),
            const SizedBox(height: AppTokens.spaceSm),
            if (widget.lockedType != null)
              Text(
                manualSourceTypeLabel(_type),
                style: theme.textTheme.bodyMedium,
              )
            else
              SegmentedButton<SourceType>(
                segments: <ButtonSegment<SourceType>>[
                  for (final t in SourceType.values)
                    ButtonSegment<SourceType>(
                      value: t,
                      label: Text(manualSourceTypeLabel(t)),
                    ),
                ],
                selected: <SourceType>{_type},
                onSelectionChanged: (Set<SourceType> selection) {
                  AppHaptics.selectionClick();
                  setState(() => _type = selection.first);
                  _clearError();
                },
              ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceMd),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }
}
