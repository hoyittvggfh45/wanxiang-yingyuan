/// 蜘蛛引擎状态横条：源列表里有 py/jar 源、但原生引擎未接通时显示。
///
/// 引擎接通后横条自动消失（[PyBridge]/[JarBridge] 的 `status` 探测）。
library;

import 'package:material_ui/material_ui.dart';

import '../../../core/spider/spider_bridges.dart';
import '../../../core/spider/spider_errors.dart';
import '../../../core/theme/app_tokens.dart';

class SpiderEngineBanner extends StatelessWidget {
  /// 列表里是否有 py 源 / jar 源。
  final bool hasPySources;
  final bool hasJarSources;

  const SpiderEngineBanner({
    super.key,
    required this.hasPySources,
    required this.hasJarSources,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasPySources && !hasJarSources) return const SizedBox.shrink();
    return FutureBuilder<(bool, bool)>(
      future: Future.wait(<Future<bool>>[
        hasPySources ? PyBridge.isConnected() : Future.value(true),
        hasJarSources ? JarBridge.isConnected() : Future.value(true),
      ]).then((List<bool> r) => (r[0], r[1])),
      builder: (BuildContext ctx, AsyncSnapshot<(bool, bool)> snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final (bool pyOk, bool jarOk) = snap.data!;
        if (pyOk && jarOk) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceSm,
            AppTokens.spaceMd,
            0,
          ),
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          decoration: BoxDecoration(
            color: Theme.of(ctx).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(ctx).colorScheme.onErrorContainer,
              ),
              const SizedBox(width: AppTokens.spaceSm),
              Expanded(
                child: Text(
                  spiderEngineNotConnectedMessage,
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
