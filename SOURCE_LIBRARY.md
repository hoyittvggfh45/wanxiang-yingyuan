# 随包内置源库说明

- 来源仓库：`nexhub-app/sources`（NexHub 官方源库）
- 提交：`cc897f8`（与线上一致，2026-11-12 核对）
- 拉取日期：2026-11-12
- 内容：`index.json` 清单 + `sources/` 下 47 条规则 JSON（media 31 条、manga 12 条、novel 4 条），内容原样复制，未改动。
- 存放位置：`assets/source_library/`（`index.json` + `sources/<分类>/<id>.json`）
- 许可：原仓库内未见 LICENSE 文件，许可状态以原仓库为准；本文件仅作来源记录。
- 使用方式：应用内「官方源库」默认订阅读包内副本（`asset:` 哨兵地址，见
  `lib/core/services/source_library_loader.dart`），不联网、不依赖原作者 CDN
  地址；用户自填的订阅地址不受影响。
- 校验：复制后全部 48 个文件的 md5 校验和与来源一致。
