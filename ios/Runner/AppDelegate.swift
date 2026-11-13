import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // iOS 侧 py 蜘蛛引擎（CPython 嵌入式）：与安卓同一套宿主协议，
    // 内置 py 与导入 py 走同一条引擎链路；初始化失败时 Dart 侧诚实报未接通。
    PySpiderBridge.register(with: self.registrar(forPlugin: "PySpiderBridge")!)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
