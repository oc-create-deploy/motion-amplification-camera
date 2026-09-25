import Accelerate
import AVFoundation
import CoreImage
import MetalKit
import Photos
import Vision

enum EngineError: LocalizedError {
  case noCamera, invalidBand(String), configuration(String)
  var errorDescription: String? { switch self { case .noCamera: return "No compatible rear camera is available."; case .invalidBand(let s), .configuration(let s): return s } }
}

final class MotionCameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let device: MTLDevice
  private let session = AVCaptureSession(), sessionQueue = DispatchQueue(label: "camera.session"), processingQueue = DispatchQueue(label: "camera.processing", qos: .userInitiated)
  private let output = AVCaptureVideoDataOutput(), commandQueue: MTLCommandQueue, ciContext: CIContext
  private var camera: AVCaptureDevice?, textureCache: CVMetalTextureCache?, view: MTKView?
  private var pipeline: MTLComputePipelineState?, fastState: MTLTexture?, slowState: MTLTexture?, outputTexture: MTLTexture?
  private var roi = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.4)
  private var previousPixelBuffer: CVPixelBuffer?, lastTimestamp: CMTime?, fpsTimes = [Double](), displacement = [(time: Double, x: Double, y: Double)]()
  private var analyzing = false, needsReset = true, targetFPS = 60.0, measuredFPS = 0.0, lowerHz = 1.0, upperHz = 8.0, gain = 20.0, quality = "balanced", colorMode = "luminance"
  private var latestImage: CIImage?, droppedFrames = 0, frameIndex = 0, frameWidth = 0, registrationAttempts = 0, registrationSuccesses = 0
  var onStatus: (([String: Any]) -> Void)?

  override init() {
    guard let gpu = MTLCreateSystemDefaultDevice(), let queue = gpu.makeCommandQueue() else { fatalError("Metal is required") }
    device = gpu; commandQueue = queue; ciContext = CIContext(mtlDevice: gpu)
    super.init(); CVMetalTextureCacheCreate(nil, nil, gpu, nil, &textureCache)
    if let library = try? gpu.makeDefaultLibrary(bundle: .main), let function = library.makeFunction(name: "amplifyLuma") { pipeline = try? gpu.makeComputePipelineState(function: function) }
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
  }

  deinit { NotificationCenter.default.removeObserver(self); UIDevice.current.endGeneratingDeviceOrientationNotifications() }
  @objc private func orientationChanged() {
    guard let connection = output.connection(with: .video) else { return }
    let orientation = UIDevice.current.orientation
    if #available(iOS 17.0, *) {
      let angle: CGFloat = orientation == .landscapeLeft ? 0 : (orientation == .landscapeRight ? 180 : 90)
      if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    } else if orientation == .landscapeLeft { connection.videoOrientation = .landscapeRight } else if orientation == .landscapeRight { connection.videoOrientation = .landscapeLeft } else { connection.videoOrientation = .portrait }
    resetFilter(reason: "Orientation changed — filter reset.")
  }

  func attach(view: MTKView) { self.view = view }
  func startCapture() { sessionQueue.async { [weak self] in self?.configureSessionIfNeeded() } }
  private func configureSessionIfNeeded() {
    guard session.inputs.isEmpty else { if !session.isRunning { session.startRunning() }; return }
    session.beginConfiguration(); session.sessionPreset = .inputPriority
    guard let found = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: found), session.canAddInput(input) else { session.commitConfiguration(); return }
    camera = found; session.addInput(input)
    let selection = Self.bestFormat(for: found)
    do { try found.lockForConfiguration(); found.activeFormat = selection.format; found.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(selection.fps)); found.activeVideoMaxFrameDuration = found.activeVideoMinFrameDuration; if found.isSmoothAutoFocusSupported { found.isSmoothAutoFocusEnabled = true }; found.unlockForConfiguration(); targetFPS = selection.fps } catch {}
    output.alwaysDiscardsLateVideoFrames = true; output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.setSampleBufferDelegate(self, queue: processingQueue); if session.canAddOutput(output) { session.addOutput(output) }
    if let connection = output.connection(with: .video) { if #available(iOS 17.0, *) { connection.videoRotationAngle = 90 } else { connection.videoOrientation = .portrait } }
    session.commitConfiguration(); session.startRunning(); emitStatus()
  }

  static func bestFormat(for device: AVCaptureDevice, prefer120: Bool = false) -> (format: AVCaptureDevice.Format, fps: Double) {
    let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Double, Int32, Int32)? in
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let rates = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).filter { $0 >= 55 }
      guard let maxRate = rates.max(), dims.width >= 640 else { return nil }
      let preferred = maxRate >= 119 ? 120.0 : min(60.0, maxRate)
      return (format, preferred, dims.width, dims.height)
    }
    return candidates.sorted { a, b in
      let aFPS = prefer120 ? (a.1 >= 120 ? 2 : 1) : (abs(a.1 - 60) < 1 ? 2 : (a.1 >= 120 ? 1 : 0))
      let bFPS = prefer120 ? (b.1 >= 120 ? 2 : 1) : (abs(b.1 - 60) < 1 ? 2 : (b.1 >= 120 ? 1 : 0))
      if aFPS != bFPS { return aFPS > bFPS }; return a.2 * a.3 > b.2 * b.3
    }.first.map { ($0.0, $0.1) } ?? (device.activeFormat, 30)
  }

  func configure(_ args: [String: Any]) throws {
    lowerHz = args["lowerHz"] as? Double ?? 1; upperHz = args["upperHz"] as? Double ?? 8; gain = args["gain"] as? Double ?? 20
    quality = args["quality"] as? String ?? "balanced"; colorMode = args["colorMode"] as? String ?? "luminance"
    let fps = measuredFPS > 0 ? measuredFPS : targetFPS
    guard lowerHz > 0, upperHz > lowerHz, upperHz < 0.45 * fps else { throw EngineError.invalidBand("Choose 0 < lower < upper < 0.45 × measured FPS.") }
    resetFilter(reason: nil)
    if quality == "performance" { requestHighSpeedIfAvailable() }
  }
  private func requestHighSpeedIfAvailable() {
    sessionQueue.async { [weak self] in
      guard let self, let camera else { return }
      let selection = Self.bestFormat(for: camera, prefer120: true)
      guard selection.fps >= 119, selection.format !== camera.activeFormat else { return }
      do { try camera.lockForConfiguration(); camera.activeFormat = selection.format; camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 120); camera.activeVideoMaxFrameDuration = camera.activeVideoMinFrameDuration; camera.unlockForConfiguration(); targetFPS = 120; resetFilter(reason: "Capture format changed — filter reset.") } catch {}
    }
  }
  func startAnalysis() throws { guard camera != nil else { throw EngineError.noCamera }; analyzing = true; resetFilter(reason: nil); emitStatus() }
  func stopAnalysis() { analyzing = false; emitStatus() }
  func setROI(_ args: [String: Any]) { roi = CGRect(x: args["left"] as? Double ?? 0.2, y: args["top"] as? Double ?? 0.25, width: args["width"] as? Double ?? 0.6, height: args["height"] as? Double ?? 0.4).standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)); resetFilter(reason: nil) }
  func resetROI() { roi = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.4); resetFilter(reason: nil) }
  func setLock(kind: String, locked: Bool) throws { guard let camera else { throw EngineError.noCamera }; try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }; switch kind { case "focus": if camera.isFocusModeSupported(locked ? .locked : .continuousAutoFocus) { camera.focusMode = locked ? .locked : .continuousAutoFocus }; case "exposure": if camera.isExposureModeSupported(locked ? .locked : .continuousAutoExposure) { camera.exposureMode = locked ? .locked : .continuousAutoExposure }; case "whiteBalance": if camera.isWhiteBalanceModeSupported(locked ? .locked : .continuousAutoWhiteBalance) { camera.whiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance }; default: break } }
  func setTorch(_ enabled: Bool) throws { guard let camera, camera.hasTorch else { throw EngineError.configuration("Torch is not available.") }; try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }; if enabled { try camera.setTorchModeOn(level: min(AVCaptureDevice.maxAvailableTorchLevel, 0.5)) } else { camera.torchMode = .off } }
  private func resetFilter(reason: String?) { needsReset = true; lastTimestamp = nil; displacement.removeAll(keepingCapacity: true); previousPixelBuffer = nil; registrationAttempts = 0; registrationSuccesses = 0; if let reason { emitStatus(warning: reason) } }

  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { droppedFrames += 1 }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    frameWidth = CVPixelBufferGetWidth(pixel)
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer), seconds = timestamp.seconds
    var dt = lastTimestamp.map { timestamp.seconds - $0.seconds } ?? 0
    if dt <= 0 || dt > 0.25 { resetFilter(reason: dt > 0.25 ? "Frame discontinuity — filter reset." : nil); dt = 0 }
    lastTimestamp = timestamp; fpsTimes.append(seconds); while fpsTimes.count > 2 && seconds - fpsTimes[0] > 1 { fpsTimes.removeFirst() }; if fpsTimes.count > 1 { measuredFPS = Double(fpsTimes.count - 1) / max(0.001, seconds - fpsTimes[0]) }
    render(pixelBuffer: pixel, dt: Float(dt)); frameIndex += 1
    let registrationStride = quality == "detail" ? 2 : (quality == "performance" ? 4 : 3)
    if analyzing && frameIndex % registrationStride == 0 { register(pixelBuffer: pixel, timestamp: seconds) }
    if frameIndex % 6 == 0 { emitStatus(warning: warning(for: pixel)) }
  }

  private func ensureTextures(width: Int, height: Int) {
    if fastState?.width == width && fastState?.height == height && !needsReset { return }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false); descriptor.usage = [.shaderRead, .shaderWrite]
    fastState = device.makeTexture(descriptor: descriptor); slowState = device.makeTexture(descriptor: descriptor); outputTexture = device.makeTexture(descriptor: descriptor); needsReset = true
  }
  private func render(pixelBuffer: CVPixelBuffer, dt: Float) {
    guard let cache = textureCache, let pipeline, let drawable = view?.currentDrawable else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer); ensureTextures(width: width, height: height)
    var cvTexture: CVMetalTexture?; CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
    guard let input = cvTexture.flatMap(CVMetalTextureGetTexture), let fastState, let slowState, let rendered = outputTexture, let command = commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return }
    encoder.setComputePipelineState(pipeline); encoder.setTexture(input, index: 0); encoder.setTexture(fastState, index: 1); encoder.setTexture(slowState, index: 2); encoder.setTexture(rendered, index: 3)
    var params = FilterUniforms(dt: dt, lowerHz: Float(lowerHz), upperHz: Float(upperHz), gain: analyzing ? Float(gain) : 0, reset: needsReset ? 1 : 0, luminanceOnly: colorMode == "luminance" ? 1 : 0)
    encoder.setBytes(&params, length: MemoryLayout<FilterUniforms>.stride, index: 0); let threads = MTLSize(width: 16, height: 16, depth: 1); encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: threads); encoder.endEncoding()
    guard let image = CIImage(mtlTexture: rendered, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else { return }
    let sx = CGFloat(drawable.texture.width) / image.extent.width, sy = CGFloat(drawable.texture.height) / image.extent.height
    let displayImage = image.transformed(by: CGAffineTransform(scaleX: max(sx, sy), y: max(sx, sy)))
    ciContext.render(displayImage, to: drawable.texture, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height), colorSpace: CGColorSpaceCreateDeviceRGB()); latestImage = image; command.present(drawable); command.commit(); needsReset = false
  }

  private func register(pixelBuffer: CVPixelBuffer, timestamp: Double) {
    guard let prior = previousPixelBuffer else { previousPixelBuffer = clone(pixelBuffer); return }
    registrationAttempts += 1
    let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pixelBuffer)
    request.regionOfInterest = roi
    do { try VNImageRequestHandler(cvPixelBuffer: prior, orientation: .up).perform([request]); guard let alignment = request.results?.first as? VNImageTranslationAlignmentObservation else { return }; registrationSuccesses += 1; let x = Double(alignment.alignmentTransform.tx), y = Double(alignment.alignmentTransform.ty); displacement.append((timestamp, x, y)); if displacement.count > 512 { displacement.removeFirst(displacement.count - 512) } } catch {}
  }
  private func clone(_ source: CVPixelBuffer) -> CVPixelBuffer? { var copy: CVPixelBuffer?; CVPixelBufferCreate(nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), CVPixelBufferGetPixelFormatType(source), nil, &copy); guard let copy else { return nil }; CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(copy, []); defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(copy, []) }; memcpy(CVPixelBufferGetBaseAddress(copy), CVPixelBufferGetBaseAddress(source), min(CVPixelBufferGetDataSize(source), CVPixelBufferGetDataSize(copy))); return copy }

  private func metrics() -> (x: Double, y: Double, rms: Double, peak: Double, frequency: Double, confidence: Double) {
    guard let last = displacement.last else { return (0, 0, 0, 0, 0, 0) }; let recent = Array(displacement.suffix(256)); let magnitudes = recent.map { hypot($0.x, $0.y) }; var squares = magnitudes.map { Float($0 * $0) }, meanSquare: Float = 0; vDSP_meanv(&squares, 1, &meanSquare, vDSP_Length(squares.count)); let peak = magnitudes.max() ?? 0
    let frequency = FrequencyEstimator.dominantFrequency(samples: recent.map { Float($0.x) }, timestamps: recent.map(\.time), lowerHz: lowerHz, upperHz: upperHz)
    let trackingSuccess = registrationAttempts > 0 ? Double(registrationSuccesses) / Double(registrationAttempts) : 0
    let confidence = trackingSuccess * min(1, Double(recent.count) / 60); return (last.x, last.y, sqrt(Double(meanSquare)), peak, frequency, confidence)
  }
  private func warning(for pixel: CVPixelBuffer) -> String? { if measuredFPS > 0 && upperHz >= 0.45 * measuredFPS { return "Band exceeds the Nyquist-safe limit for measured FPS." }; if droppedFrames > 3 { droppedFrames = 0; return "Frames dropped — reduce processing quality or improve lighting." }; if let camera, camera.iso > camera.activeFormat.maxISO * 0.8 { return "Low light — add steady lighting and avoid flicker." }; if let camera, abs(camera.exposureTargetOffset) > 1.5 { return "Exposure clipping risk — adjust lighting or exposure." }; let m = metrics(); if m.peak > 12 { return "Excessive camera/scene motion; stabilize the tripod." }; if m.confidence < 0.35 && analyzing { return "Low tracking confidence; select a textured ROI." }; return nil }
  func emitStatus(warning: String? = nil) { let m = metrics(); var status: [String: Any] = ["targetFps": targetFPS, "measuredFps": measuredFPS, "frameWidth": frameWidth, "torchAvailable": camera?.hasTorch ?? false, "running": analyzing, "x": m.x, "y": m.y, "rms": m.rms, "peak": m.peak, "frequency": m.frequency, "confidence": m.confidence, "timestamp": lastTimestamp?.seconds ?? 0, "quality": warning == nil ? (analyzing ? "good" : "idle") : qualityName(warning!)]; if let warning { status["warning"] = warning }; onStatus?(status) }
  private func qualityName(_ warning: String) -> String { if warning.contains("dropped") { return "droppedFrames" }; if warning.contains("texture") { return "lowTexture" }; if warning.contains("motion") { return "cameraMotion" }; if warning.contains("Band") { return "invalidBand" }; if warning.contains("Low light") { return "lowLight" }; return "clipping" }
  func saveSnapshot(completion: @escaping (Bool, String) -> Void) { guard let latestImage, let cg = ciContext.createCGImage(latestImage, from: latestImage.extent) else { completion(false, "No camera frame is available."); return }; PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in guard status == .authorized || status == .limited else { completion(false, "Photo access was not granted."); return }; PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: cg)) }) { success, error in completion(success, success ? "Saved" : (error?.localizedDescription ?? "Could not save snapshot.")) } } }
}

private struct FilterUniforms { var dt, lowerHz, upperHz, gain: Float; var reset, luminanceOnly: UInt32 }

enum FrequencyEstimator {
  static func dominantFrequency(samples: [Float], timestamps: [Double], lowerHz: Double, upperHz: Double) -> Double {
    guard samples.count >= 32, let first = timestamps.first, let last = timestamps.last, last > first else { return 0 }
    let count = 1 << Int(floor(log2(Double(samples.count)))), rate = Double(count - 1) / (last - first); var signal = Array(samples.suffix(count)), window = [Float](repeating: 0, count: count); vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM)); vDSP_vmul(signal, 1, window, 1, &signal, 1, vDSP_Length(count))
    guard let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: count, direction: .forward, transformType: .complexComplex, ofType: Float.self) else { return 0 }; let zeros = [Float](repeating: 0, count: count); let spectrum = dft.transform(real: signal, imaginary: zeros); let real = spectrum.real, imag = spectrum.imaginary; var power = [Float](repeating: 0, count: count / 2); for index in power.indices { power[index] = real[index] * real[index] + imag[index] * imag[index] }
    let low = max(1, Int(ceil(lowerHz * Double(count) / rate))), high = min(power.count - 1, Int(floor(upperHz * Double(count) / rate))); guard high >= low else { return 0 }; let index = (low...high).max(by: { power[$0] < power[$1] }) ?? low; return Double(index) * rate / Double(count)
  }
}
