# iOS 版 py 蜘蛛引擎

本文档记录万象影院 iOS 版嵌入 CPython 的方案、打包物与维护约定。
安卓那条线（Chaquopy）在 `android/app/src/main/`，与本目录无关，两边
宿主协议文件必须保持同步（见“双份同步”一节）。

## 路线

BeeWare **Python-Apple-support** 的预编译 `Python.xcframework`（官方
PEP 730 iOS 嵌入式构建），版本 **3.13-b18**（CPython 3.13.18、
OpenSSL 3.5.9-1、最低 iOS 13.0，2026-10-26 发布）。下载地址：

`https://github.com/beeware/Python-Apple-support/releases/download/3.13-b18/Python-3.13-iOS-support.b18.tar.gz`

集成法按 CPython 官方文档《Using Python on iOS》与 CPython 源码自带
iOS testbed（`TestbedTests/TestbedTests.m`）：XCFramework 入工程并
Embed & Sign；构建设置关 quoted-include 警告、加 Framework/Header
搜索路径；Run Script 阶段调 `install_python` 把标准库与扩展模块
处理进包内；初始化用隔离配置，`PYTHONHOME` 指包内 `python/` 子目录。

链路：Dart `PyBridge` → 通道 `wxyy/pybridge` → `Runner/PySpiderBridge.m`
→ 解释器内 `pycode/py_spider_host.py` → 蜘蛛源码（每次随 `args["source"]`
传来）。内置 py 与导入 py 在 Dart 侧由 `PySourceStore` 统一取源码，
原生侧不分内置导入，走同一条链路。jar 站 iOS 本来就没有，不碰。

## 打包物

| 位置 | 内容 | 体积 |
| --- | --- | --- |
| `ios/Python.xcframework/` | CPython 3.13.18 双 slice（设备 arm64 + 模拟器 arm64/x86_64）、标准库、`build/utils.sh` | 约 78MB（已裁剪，见下） |
| `ios/py_packages/` | 纯 Python 第三方包（见下） | 约 1.5MB |
| `ios/pycode/` | 宿主 `py_spider_host.py` + 基类 `base/spider.py`（与安卓侧逐字节相同） | 约 20KB |
| `ios/Runner/PySpiderBridge.h` / `.m` | 原生桥：`status` / `call` / `release`，单线程串行队列，结果回主线程 | 约 18KB |

### 裁剪清单（Python.xcframework）

原包 121MB → 78MB。删掉的全是运行时无用的东西：

- 标准库 `test/`（CPython 自带测试套件，35MB）、`idlelib/`、
  `ensurepip/`、`tkinter/`、`turtledemo/`；
- 两 slice 的 `bin/`（编译器 stub）与 `include/`（与
  `Python.framework/Headers` 重复的头文件）。

保留：`Info.plist`、`build/utils.sh` + dylib 模板 plist、共享 `lib/`、
两 slice 的 `Python.framework`、`lib/`、`lib-$ARCHS/`、`platform-config`。
设备 slice 的 `lib-dynload/` 有 68 个扩展模块，含 `_ssl`（HTTPS 靠它）。

### 捆了的第三方包（py_packages，全是纯 Python，无二进制扩展）

- requests 2.34.2、urllib3 2.8.0、certifi 2026.10.23（含 cacert.pem）、
  idna 3.20、charset-normalizer 3.0.1。

### 没捆的依赖与影响

- **pycryptodome（Crypto）没捆**：它是 C 扩展，iOS 上要另行编译。
  影响：9 个蜘蛛（danai、dj91、guohnsqj、hgai、javzw、luoliai、
  theporny、xlook、ywly）会 `import Crypto`，但全部在
  `_aes_cbc_decrypt` 内有纯 Python AES 回退（`_expand_key` /
  `_decrypt_block`），Crypto 导入失败时走回退，不会损坏。
- bs4、lxml、pyquery、cloudscraper、httpx、websocket：131 个蜘蛛
  里出现次数为 0，不需要捆。
- requests：107 个蜘蛛提到，全部是 `try: import requests` 保护式导入；
  即便 `py_packages` 失效，宿主也会注入 urllib 版 requests 替身
  （`_ensure_requests`），蜘蛛照常跑。

## 双份同步（铁律）

`ios/pycode/py_spider_host.py` 与 `ios/pycode/base/spider.py` 必须与
`android/app/src/main/python/` 下同名文件**逐字节相同**。改宿主协议
或基类时，两份一起改。`test/py_host_sync_test.dart` 在漂移时失败。

## 工程改动（Runner.xcodeproj）

- 新增 5 个文件引用：`Python.xcframework`、`pycode` 文件夹、
  `py_packages` 文件夹、`PySpiderBridge.h`、`.m`。
- `Python.xcframework` 进 Frameworks 与 Embed Frameworks（Embed & Sign）；
  `pycode`、`py_packages` 进 Resources（进包根目录，原名文件夹）；
  `PySpiderBridge.m` 进 Sources。
- 新增 Run Script 阶段 **“Process Python libraries”**，顺序在
  Copy Bundle Resources 之后、Embed Frameworks 之前：
  `install_python Python.xcframework pycode py_packages`。
  该脚本把标准库拷进包内 `python/lib/`，把每个 `.so` 转成
  `Frameworks/<模块>.framework` 并签名。
- 三个 Runner target 配置（Debug/Release/Profile）各加：
  `CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = NO`、
  `FRAMEWORK_SEARCH_PATHS = $(inherited) $(PROJECT_DIR)`、
  `HEADER_SEARCH_PATHS = $(inherited) $(BUILT_PRODUCTS_DIR)/Python.framework/Headers`。
- 已有且不需改的设置：`ENABLE_USER_SCRIPT_SANDBOXING = NO`（三个
  project 配置里已有）；`LD_RUNPATH_SEARCH_PATHS` 已含
  `@executable_path/Frameworks`。

### 无签名构建的签名回退

`install_dylib`（`utils.sh` 内）执行
`codesign --sign "$EXPANDED_CODE_SIGN_IDENTITY"`。无签名构建
（CI 的 `flutter build ios --no-codesign`）时该变量为空，codesign
会失败。Run Script 阶段里若变量为空则覆写为 `"-"`（ad-hoc 签名），
不改 vendored 的 `utils.sh`。注意：ad-hoc 签名的 `.framework` 在
真机分发前需由最终签名步骤重签；CI 产出本就是未签名 IPA，
自签/越狱侧载流程会重签整个包。

## 运行时布局（包内）

```
Runner.app/
  Frameworks/
    Python.framework/            ← XCFramework 设备 slice
    _ssl.framework/ …            ← 68 个扩展模块，各成一个 framework
  python/
    lib/python3.13/              ← 标准库（含 lib-dynload 占位）
  pycode/
    py_spider_host.py
    base/spider.py
  py_packages/
    requests/ urllib3/ certifi/ idna/ charset_normalizer/
```

桥初始化时：`PYTHONHOME` = 包内 `python/`；`site.addsitedir(py_packages)`；
`sys.path` 首位插 `pycode`。初始化顺序与 testbed 一致：
`PyPreConfig_InitIsolatedConfig` → `PyConfig_InitIsolatedConfig` →
设标志 → `Py_PreInitialize` → 设 `home` → `PyConfig_Read` →
`PyConfig_SetBytesArgv` → `Py_InitializeFromConfig`。

注意：3.13 头文件里没有 `use_system_logger` 字段（3.14 才有），
桥里不设它；升级 Python 大版本时再看。

## 诚实未接通

解释器初始化或宿主导入失败时，`status` 返回
`{'connected': false, 'error': <真实原因>}`，`call` 报 `NOT_CONNECTED`，
Dart 侧译成 `SpiderEngineException(notConnected: true)`，由现有的
`SpiderEngineBanner` 展示。绝不假装通了。

## 验过 / 未验

已验（本机 Linux VM，无 Xcode，只能验到主机层）：

- 宿主协议：用 iOS 副本 + `py_packages` 在系统 Python 下跑通 13 个
  分派方法 + init + release；真实蜘蛛 hghub 的 `getName` 返回 "HGhub"；
  屏蔽 requests 后替身路径正常（`status_json` 报 `requests: false`，
  蜘蛛内 `requests.get` 与 `Session` 对本地 HTTP 服务器均正常）。
- 桥契约测试：`test/py_bridge_ios_contract_test.dart`（mock 通道，
  8 个用例）与 `test/py_host_sync_test.dart`（17 个用例）全过；
  `flutter analyze` 0 error。
- 工程文件：全部 65 个对象 ID 有定义无悬引、大括号平衡、phase 顺序
  正确、Run Script 解码后与预期一致；桥用到的全部 C API 符号在
  vendored 头文件里有公开声明。

未验（须 macOS + Xcode / 真机）：

- 原生编译：`PySpiderBridge.m` 在 Xcode 里能不能编过（本机无 Xcode，
  只做了头文件符号核对）。
- Run Script 阶段在 `xcodebuild` 里能不能跑通（`install_python` 的
  rsync/plutil/codesign 路径、ad-hoc 回退）。
- 真机运行：解释器初始化、宿主导入、内置/导入 py 真站调用、
  `_ssl` 真实 HTTPS、包体积与启动时间。
- 模拟器 slice 未在任何模拟器上跑过。

## 升级办法

新版 Python-Apple-support 发布时：下载对应 tarball，替换
`ios/Python.xcframework/`，按“裁剪清单”重做裁剪，核对
`build/utils.sh` 的 `install_python` 语义没变，更新本文档的版本号，
重跑 `test/py_host_sync_test.dart` 与 `test/py_bridge_ios_contract_test.dart`。
