import Flutter
import Foundation

final class CameraBridge: NSObject, FlutterStreamHandler {
  static let shared = CameraBridge()
  let engine = MotionCameraEngine()
  private var events: FlutterEventSink?

  func attach(to messenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(name: "motion_amplification/camera", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    FlutterEventChannel(name: "motion_amplification/measurements", binaryMessenger: messenger).setStreamHandler(self)
    engine.onStatus = { [weak self] value in DispatchQueue.main.async { self?.events?(value) } }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "configure": try engine.configure(args); result(nil)
      case "start": try engine.startAnalysis(); result(nil)
      case "stop": engine.stopAnalysis(); result(nil)
      case "setROI": engine.setROI(args); result(nil)
      case "resetROI": engine.resetROI(); result(nil)
      case "setLock": try engine.setLock(kind: args["kind"] as? String ?? "", locked: args["locked"] as? Bool ?? false); result(nil)
      case "setTorch": try engine.setTorch(args["enabled"] as? Bool ?? false); result(nil)
      case "snapshot": engine.saveSnapshot { saved, message in
        DispatchQueue.main.async {
          if saved { result(message) }
          else { result(FlutterError(code: "snapshot", message: message, details: nil)) }
        }
      }
      default: result(FlutterMethodNotImplemented)
      }
    } catch { result(FlutterError(code: "camera", message: error.localizedDescription, details: nil)) }
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { self.events = events; engine.emitStatus(); return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { events = nil; return nil }
}
