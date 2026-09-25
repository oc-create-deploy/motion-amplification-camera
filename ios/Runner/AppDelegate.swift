import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    CameraBridge.shared.attach(to: messenger)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MotionCamera") {
      registrar.register(
        CameraViewFactory(
          engine: CameraBridge.shared.engine,
          messenger: messenger
        ),
        withId: "motion_amplification/camera_view"
      )
    }
  }
}
