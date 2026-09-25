import Flutter
import MetalKit
import UIKit

final class CameraViewFactory: NSObject, FlutterPlatformViewFactory {
  private let engine: MotionCameraEngine
  init(engine: MotionCameraEngine, messenger: FlutterBinaryMessenger) { self.engine = engine; super.init() }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView { CameraPlatformView(frame: frame, engine: engine) }
}
final class CameraPlatformView: NSObject, FlutterPlatformView {
  private let metalView: MTKView
  init(frame: CGRect, engine: MotionCameraEngine) {
    metalView = MTKView(frame: frame, device: engine.device)
    metalView.framebufferOnly = false; metalView.enableSetNeedsDisplay = true; metalView.isPaused = true
    metalView.contentMode = .scaleAspectFill; metalView.accessibilityLabel = "Live processed camera with selectable region of interest"
    super.init(); engine.attach(view: metalView); engine.startCapture()
  }
  func view() -> UIView { metalView }
}
