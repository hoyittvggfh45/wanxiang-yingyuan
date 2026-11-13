#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// iOS 侧 py 蜘蛛引擎：CPython 嵌入式解释器，跑与安卓同一套宿主协议。
///
/// 通道与方法名与安卓侧 `SpiderBridge.kt` 完全一致（`wxyy/pybridge` 的
/// `status` / `call` / `release`），Dart 侧 `PyBridge` 不分平台共用。
/// 解释器初始化失败时 `status` 报 `connected: false`，`call` 报
/// `NOT_CONNECTED`，走现有诚实未接通机制，绝不假装通了。
@interface PySpiderBridge : NSObject

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar;

@end

NS_ASSUME_NONNULL_END
