import Accelerate
import AVFoundation
import CoreImage
import MetalKit
import Photos
import QuartzCore
import Vision

enum EngineError: LocalizedError {
  case noCamera, invalidBand(String), configuration(String)
  var errorDescription: String? { switch self { case .noCamera: return "No compatible rear camera is available."; case .invalidBand(let s), .configuration(let s): return s } }
}

final class MotionCameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, MTKViewDelegate {
  let device: MTLDevice
  private let session = AVCaptureSession(), sessionQueue = DispatchQueue(label: "camera.session"), processingQueue = DispatchQueue(label: "camera.processing", qos: .userInitiated)
  private let output = AVCaptureVideoDataOutput(), commandQueue: MTLCommandQueue, ciContext: CIContext
  private var camera: AVCaptureDevice?, textureCache: CVMetalTextureCache?, view: MTKView?
  private weak var previewLayer: CALayer?
  private var pipeline: MTLComputePipelineState?, fastState: MTLTexture?, slowState: MTLTexture?, outputTexture: MTLTexture?
  private var roi = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.4)
  private var previousPixelBuffer: CVPixelBuffer?, lastTimestamp: CMTime?, fpsTimes = [Double](), displacement = [(time: Double, x: Double, y: Double)]()
  private var analyzing = false, needsReset = true, targetFPS = 60.0, measuredFPS = 0.0, lowerHz = 1.0, upperHz = 8.0, gain = 20.0, quality = "balanced", colorMode = "luminance"
  private var latestImage: CIImage?, droppedFrames = 0, frameIndex = 0, frameWidth = 0, registrationAttempts = 0, registrationSuccesses = 0
  private var cameraReady = false, previewActive = false, recordingRequested = false
  private var renderFailure: String?
  // EXIF orientation applied in Core Image when an AVCapture connection cannot
  // rotate buffers in hardware (observed on current iPhone/iOS combinations).
  private var softwareExifOrientation: Int32 = 1
  private var recorder: AmplifiedVideoRecorder?, recordingURL: URL?, recordingError: String?
  private var recordingStartedAt: CMTime?, recordedDuration = 0.0
  var onStatus: (([String: Any]) -> Void)?
  var isAmplificationPipelineReadyForTesting: Bool { pipeline != nil }

  override init() {
    guard let gpu = MTLCreateSystemDefaultDevice(), let queue = gpu.makeCommandQueue() else { fatalError("Metal is required") }
    device = gpu; commandQueue = queue; ciContext = CIContext(mtlDevice: gpu)
    super.init(); CVMetalTextureCacheCreate(nil, nil, gpu, nil, &textureCache)
    pipeline = Self.makeAmplificationPipeline(device: gpu)
    if pipeline == nil {
      renderFailure = "The Metal motion-amplification shader could not be loaded."
    }
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
  }

  private static func makeAmplificationPipeline(device: MTLDevice) -> MTLComputePipelineState? {
    // `makeDefaultLibrary(bundle:)` has failed to locate Flutter's compiled
    // default.metallib on some physical-device/App Store builds. Search both
    // supported default-library paths before falling back to an embedded copy
    // of the same kernel so the camera path never silently produces no frames.
    let bundledLibrary = try? device.makeDefaultLibrary(bundle: .main)
    let library = bundledLibrary ?? device.makeDefaultLibrary()
    if let function = library?.makeFunction(name: "amplifyLuma"),
       let state = try? device.makeComputePipelineState(function: function) {
      return state
    }
    guard let runtimeLibrary = try? device.makeLibrary(source: amplificationKernelSource, options: nil),
          let function = runtimeLibrary.makeFunction(name: "amplifyLuma") else {
      return nil
    }
    return try? device.makeComputePipelineState(function: function)
  }

  deinit { NotificationCenter.default.removeObserver(self); UIDevice.current.endGeneratingDeviceOrientationNotifications() }
  @objc private func orientationChanged() {
    let orientation = UIDevice.current.orientation
    sessionQueue.async { [weak self] in
      guard let self, let connection = output.connection(with: .video) else { return }
      applyVideoOrientation(orientation, to: connection)
      processingQueue.async { [weak self] in self?.resetFilter(reason: "Orientation changed — filter reset.") }
    }
  }

  private func applyVideoOrientation(_ orientation: UIDeviceOrientation, to connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
      let coordinatedAngle = camera.map {
        // This is a custom Metal preview, so use the coordinator's preview
        // compensation rather than its capture compensation. On the reported
        // physical device those angles differ by 180 degrees, which made the
        // preview appear upside down even though the frame was portrait-sized.
        AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: previewLayer)
          .videoRotationAngleForHorizonLevelPreview
      }
      let angle = coordinatedAngle ?? Self.fallbackVideoRotationAngle(for: orientation)
      if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
        softwareExifOrientation = 1
      } else {
        softwareExifOrientation = Self.exifOrientation(forClockwiseRotationAngle: angle)
      }
    } else {
      if connection.isVideoOrientationSupported {
        if orientation == .landscapeLeft { connection.videoOrientation = .landscapeRight } else if orientation == .landscapeRight { connection.videoOrientation = .landscapeLeft } else { connection.videoOrientation = .portrait }
        softwareExifOrientation = 1
      } else {
        softwareExifOrientation = Self.exifOrientation(
          forClockwiseRotationAngle: Self.fallbackVideoRotationAngle(for: orientation)
        )
      }
    }
  }

  static func fallbackVideoRotationAngle(for orientation: UIDeviceOrientation) -> CGFloat {
    switch orientation {
    case .landscapeLeft: return 0
    case .landscapeRight: return 180
    case .portraitUpsideDown: return 270
    default: return 90
    }
  }

  static func exifOrientation(forClockwiseRotationAngle angle: CGFloat) -> Int32 {
    let normalized = (angle.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360)
    let quarterTurn = Int((normalized / 90).rounded()) % 4
    switch quarterTurn {
    case 1: return 6
    case 2: return 3
    case 3: return 8
    default: return 1
    }
  }

  func attach(view: MTKView) {
    self.view = view
    previewLayer = view.layer
    view.device = device
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = false
    view.enableSetNeedsDisplay = true
    view.isPaused = true
    view.delegate = self
  }

  func startCapture() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      sessionQueue.async { [weak self] in self?.configureSessionIfNeeded() }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard let self else { return }
        if granted {
          sessionQueue.async { [weak self] in self?.configureSessionIfNeeded() }
        } else {
          emitStatus(warning: "Camera permission was denied. Enable Camera in Settings.")
        }
      }
    case .denied, .restricted:
      emitStatus(warning: "Camera access is unavailable. Enable Camera in Settings.")
    @unknown default:
      emitStatus(warning: "Camera access could not be determined.")
    }
  }
  private func configureSessionIfNeeded() {
    guard session.inputs.isEmpty else { if !session.isRunning { session.startRunning() }; return }
    session.beginConfiguration(); session.sessionPreset = .inputPriority
    guard let found = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: found), session.canAddInput(input) else {
      session.commitConfiguration()
      emitStatus(warning: "The rear camera could not be configured.")
      return
    }
    camera = found; session.addInput(input)
    // High frame rate materially increases the usable vibration band. Prefer
    // a bounded 720p/120 mode when the camera exposes one; `bestFormat` falls
    // back to a bounded 1080p/60 mode on devices without 120 FPS capture.
    let selection = Self.bestFormat(for: found, prefer120: true)
    do { try found.lockForConfiguration(); found.activeFormat = selection.format; found.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(selection.fps)); found.activeVideoMaxFrameDuration = found.activeVideoMinFrameDuration; if found.isSmoothAutoFocusSupported { found.isSmoothAutoFocusEnabled = true }; found.unlockForConfiguration(); targetFPS = selection.fps } catch {}
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    output.setSampleBufferDelegate(self, queue: processingQueue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      emitStatus(warning: "The camera video output could not be configured.")
      return
    }
    session.addOutput(output)
    if let connection = output.connection(with: .video) { applyVideoOrientation(.portrait, to: connection) }
    session.commitConfiguration()
    session.startRunning()
    cameraReady = session.isRunning
    emitStatus(warning: cameraReady ? nil : "The camera session did not start.")
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
      if aFPS != bFPS { return aFPS > bFPS }
      // Four full-resolution BGRA textures are resident during processing.
      // Prefer 1080p instead of the former "largest format wins" rule, which
      // selected multi-camera 4K formats and exhausted texture memory on an
      // actual iPhone before the first preview/recording frame was published.
      let targetPixels: Int32 = prefer120 ? 1280 * 720 : 1920 * 1080
      let aDistance = abs(a.2 * a.3 - targetPixels)
      let bDistance = abs(b.2 * b.3 - targetPixels)
      if aDistance != bDistance { return aDistance < bDistance }
      return a.2 * a.3 < b.2 * b.3
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
  func startAnalysis() throws {
    guard camera != nil, cameraReady else { throw EngineError.noCamera }
    processingQueue.sync {
      recorder?.cancel()
      recorder = nil
      recordingURL = nil
      recordingError = nil
      recordingStartedAt = nil
      recordedDuration = 0
      recordingRequested = true
      analyzing = true
      resetFilter(reason: nil)
    }
    emitStatus()
  }

  func stopAnalysis(completion: @escaping (Result<RecordingResult, Error>) -> Void) {
    processingQueue.async { [weak self] in
      guard let self else { return }
      analyzing = false
      recordingRequested = false
      guard let recorder else {
        let message = recordingError ?? "No amplified frames were recorded. Keep the camera visible and try again."
        recordingError = message
        emitStatus(warning: message)
        DispatchQueue.main.async { completion(.failure(EngineError.configuration(message))) }
        return
      }
      self.recorder = nil
      recorder.finish { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let recording):
          recordingURL = recording.url
          recordedDuration = recording.durationSeconds
          recordingError = nil
          emitStatus()
          DispatchQueue.main.async { completion(.success(recording)) }
        case .failure(let error):
          recordingError = error.localizedDescription
          emitStatus(warning: error.localizedDescription)
          DispatchQueue.main.async { completion(.failure(error)) }
        }
      }
    }
  }

  func cancelAnalysis() {
    processingQueue.async { [weak self] in
      guard let self else { return }
      analyzing = false
      recordingRequested = false
      recorder?.cancel()
      recorder = nil
      recordingURL = nil
      recordingStartedAt = nil
      recordedDuration = 0
      emitStatus()
    }
  }
  func setROI(_ args: [String: Any]) { roi = CGRect(x: args["left"] as? Double ?? 0.2, y: args["top"] as? Double ?? 0.25, width: args["width"] as? Double ?? 0.6, height: args["height"] as? Double ?? 0.4).standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)); resetFilter(reason: nil) }
  func resetROI() { roi = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.4); resetFilter(reason: nil) }
  func setLock(kind: String, locked: Bool) throws { guard let camera else { throw EngineError.noCamera }; try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }; switch kind { case "focus": if camera.isFocusModeSupported(locked ? .locked : .continuousAutoFocus) { camera.focusMode = locked ? .locked : .continuousAutoFocus }; case "exposure": if camera.isExposureModeSupported(locked ? .locked : .continuousAutoExposure) { camera.exposureMode = locked ? .locked : .continuousAutoExposure }; case "whiteBalance": if camera.isWhiteBalanceModeSupported(locked ? .locked : .continuousAutoWhiteBalance) { camera.whiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance }; default: break } }
  func setTorch(_ enabled: Bool) throws { guard let camera, camera.hasTorch else { throw EngineError.configuration("Torch is not available.") }; try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }; if enabled { try camera.setTorchModeOn(level: min(AVCaptureDevice.maxAvailableTorchLevel, 0.5)) } else { camera.torchMode = .off } }
  private func resetFilter(reason: String?) { needsReset = true; lastTimestamp = nil; displacement.removeAll(keepingCapacity: true); previousPixelBuffer = nil; registrationAttempts = 0; registrationSuccesses = 0; if let reason { emitStatus(warning: reason) } }

  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { droppedFrames += 1 }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer), seconds = timestamp.seconds
    var dt = lastTimestamp.map { timestamp.seconds - $0.seconds } ?? 0
    if dt <= 0 || dt > 0.25 { resetFilter(reason: dt > 0.25 ? "Frame discontinuity — filter reset." : nil); dt = 0 }
    lastTimestamp = timestamp; fpsTimes.append(seconds); while fpsTimes.count > 2 && seconds - fpsTimes[0] > 1 { fpsTimes.removeFirst() }; if fpsTimes.count > 1 { measuredFPS = Double(fpsTimes.count - 1) / max(0.001, seconds - fpsTimes[0]) }
    render(pixelBuffer: pixel, timestamp: timestamp, dt: Float(dt)); frameIndex += 1
    let registrationStride = quality == "detail" ? 2 : (quality == "performance" ? 4 : 3)
    if analyzing && frameIndex % registrationStride == 0 { register(pixelBuffer: pixel, timestamp: seconds) }
    if frameIndex % 6 == 0 { emitStatus(warning: warning(for: pixel)) }
  }

  private func ensureTextures(width: Int, height: Int) {
    if fastState?.width == width && fastState?.height == height && !needsReset { return }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false); descriptor.usage = [.shaderRead, .shaderWrite]
    fastState = device.makeTexture(descriptor: descriptor); slowState = device.makeTexture(descriptor: descriptor); outputTexture = device.makeTexture(descriptor: descriptor); needsReset = true
  }
  private func render(pixelBuffer: CVPixelBuffer, timestamp: CMTime, dt: Float) {
    guard let cache = textureCache else {
      publishRawPreview(pixelBuffer: pixelBuffer, warning: "The Metal camera texture cache is unavailable.")
      return
    }
    guard let pipeline else {
      publishRawPreview(pixelBuffer: pixelBuffer, warning: renderFailure ?? "The amplification shader is unavailable.")
      return
    }
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer); ensureTextures(width: width, height: height)
    var cvTexture: CVMetalTexture?
    let textureStatus = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
    guard textureStatus == kCVReturnSuccess,
          let input = cvTexture.flatMap(CVMetalTextureGetTexture),
          let fastState, let slowState, let rendered = outputTexture,
          let command = commandQueue.makeCommandBuffer(),
          let encoder = command.makeComputeCommandEncoder() else {
      publishRawPreview(pixelBuffer: pixelBuffer, warning: "The camera frame could not be prepared for Metal amplification.")
      return
    }
    encoder.setComputePipelineState(pipeline); encoder.setTexture(input, index: 0); encoder.setTexture(fastState, index: 1); encoder.setTexture(slowState, index: 2); encoder.setTexture(rendered, index: 3)
    var params = FilterUniforms(dt: dt, lowerHz: Float(lowerHz), upperHz: Float(upperHz), gain: analyzing ? Float(gain) : 0, reset: needsReset ? 1 : 0, luminanceOnly: colorMode == "luminance" ? 1 : 0)
    encoder.setBytes(&params, length: MemoryLayout<FilterUniforms>.stride, index: 0); let threads = MTLSize(width: 16, height: 16, depth: 1); encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: threads); encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed,
          let rawImage = CIImage(mtlTexture: rendered, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
      publishRawPreview(pixelBuffer: pixelBuffer, warning: command.error?.localizedDescription ?? "Metal amplification could not render this frame.")
      return
    }
    let image = softwareExifOrientation == 1
      ? rawImage
      : rawImage.oriented(forExifOrientation: softwareExifOrientation)
    frameWidth = Int(image.extent.width)
    renderFailure = nil
    if recordingRequested { recordingError = nil }
    previewActive = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      latestImage = image
      view?.setNeedsDisplay()
    }
    if recordingRequested && analyzing {
      appendAmplifiedFrame(
        image,
        timestamp: timestamp,
        width: Int(image.extent.width),
        height: Int(image.extent.height)
      )
    }
    needsReset = false
  }

  private func publishRawPreview(pixelBuffer: CVPixelBuffer, warning: String) {
    let rawImage = CIImage(cvPixelBuffer: pixelBuffer)
    let image = softwareExifOrientation == 1
      ? rawImage
      : rawImage.oriented(forExifOrientation: softwareExifOrientation)
    renderFailure = warning
    recordingError = recordingRequested ? warning : recordingError
    frameWidth = Int(image.extent.width)
    previewActive = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      latestImage = image
      view?.setNeedsDisplay()
    }
    if frameIndex % 30 == 0 { emitStatus(warning: warning) }
  }

  func draw(in view: MTKView) {
    guard let image = latestImage,
          let drawable = view.currentDrawable,
          let command = commandQueue.makeCommandBuffer() else { return }
    let target = CGRect(origin: .zero, size: view.drawableSize)
    let scale = max(target.width / image.extent.width, target.height / image.extent.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let offset = CGAffineTransform(
      translationX: (target.width - scaled.extent.width) / 2 - scaled.extent.minX,
      y: (target.height - scaled.extent.height) / 2 - scaled.extent.minY
    )
    let displayImage = scaled.transformed(by: offset)
    ciContext.render(
      displayImage,
      to: drawable.texture,
      commandBuffer: command,
      bounds: target,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    command.present(drawable)
    command.commit()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  private func appendAmplifiedFrame(_ image: CIImage, timestamp: CMTime, width: Int, height: Int) {
    do {
      if recorder == nil {
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("amplified-motion-\(UUID().uuidString).mp4")
        recorder = try AmplifiedVideoRecorder(
          outputURL: url,
          width: width,
          height: height,
          expectedFPS: measuredFPS > 0 ? measuredFPS : targetFPS,
          ciContext: ciContext
        )
        recordingURL = url
      }
      try recorder?.append(image: image, timestamp: timestamp)
      if recordingStartedAt == nil { recordingStartedAt = timestamp }
      if let recordingStartedAt { recordedDuration = max(0, timestamp.seconds - recordingStartedAt.seconds) }
    } catch {
      recordingError = error.localizedDescription
      recordingRequested = false
      recorder?.cancel()
      recorder = nil
      emitStatus(warning: "Video recording stopped: \(error.localizedDescription)")
    }
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
  func emitStatus(warning: String? = nil) {
    let m = metrics()
    var status: [String: Any] = [
      "targetFps": targetFPS,
      "measuredFps": measuredFPS,
      "frameWidth": frameWidth,
      "torchAvailable": camera?.hasTorch ?? false,
      "cameraReady": cameraReady,
      "previewActive": previewActive,
      "running": analyzing,
      "recording": recorder != nil && recordingRequested,
      "recordedDuration": recordedDuration,
      "x": m.x,
      "y": m.y,
      "rms": m.rms,
      "peak": m.peak,
      "frequency": m.frequency,
      "confidence": m.confidence,
      "timestamp": lastTimestamp?.seconds ?? 0,
      "quality": warning == nil ? (analyzing ? "good" : "idle") : qualityName(warning!),
    ]
    if let recordingError { status["recordingError"] = recordingError }
    if let renderFailure, warning == nil { status["warning"] = renderFailure }
    if let warning { status["warning"] = warning }
    onStatus?(status)
  }
  private func qualityName(_ warning: String) -> String { if warning.contains("dropped") { return "droppedFrames" }; if warning.contains("texture") { return "lowTexture" }; if warning.contains("motion") { return "cameraMotion" }; if warning.contains("Band") { return "invalidBand" }; if warning.contains("Low light") { return "lowLight" }; return "clipping" }
  func saveSnapshot(completion: @escaping (Bool, String) -> Void) { guard let latestImage, let cg = ciContext.createCGImage(latestImage, from: latestImage.extent) else { completion(false, "No camera frame is available."); return }; PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in guard status == .authorized || status == .limited else { completion(false, "Photo access was not granted."); return }; PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: cg)) }) { success, error in completion(success, success ? "Saved" : (error?.localizedDescription ?? "Could not save snapshot.")) } } }

  func saveVideoToPhotos(path: String, completion: @escaping (Bool, String) -> Void) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      completion(false, "The amplified video file is no longer available.")
      return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        completion(false, "Photo access was not granted.")
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }) { success, error in
        completion(success, success ? "Saved" : (error?.localizedDescription ?? "Could not save amplified video."))
      }
    }
  }
}

struct RecordingResult {
  let url: URL
  let durationSeconds: Double
  let frameCount: Int
}

final class AmplifiedVideoRecorder {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let ciContext: CIContext
  private let outputURL: URL
  private var timeline: RealTimeVideoTimeline
  private var firstTimestamp: CMTime?
  private var lastTimestamp: CMTime?
  private(set) var frameCount = 0
  private var finished = false

  init(outputURL: URL, width: Int, height: Int, expectedFPS: Double, ciContext: CIContext) throws {
    guard width > 0, height > 0 else {
      throw EngineError.configuration("The camera produced an invalid video size.")
    }
    self.outputURL = outputURL
    self.ciContext = ciContext
    // High-speed capture is useful for motion analysis, but exported 120 FPS
    // clips can be treated as slow-motion media by players. Keep analysis at
    // the camera's full rate while exporting a standard, real-time 60 FPS
    // timeline. Excess frames are dropped rather than stretching playback.
    let exportFPS = min(60.0, max(24.0, expectedFPS.rounded()))
    timeline = RealTimeVideoTimeline(maximumOutputFPS: exportFPS)
    try? FileManager.default.removeItem(at: outputURL)
    writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let pixelCount = Double(width * height)
    let bitRate = Int(max(4_000_000, min(24_000_000, pixelCount * exportFPS * 0.10)))
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoExpectedSourceFrameRateKey: Int(exportFPS),
        AVVideoMaxKeyFrameIntervalKey: max(1, Int(exportFPS * 2)),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: attributes
    )
    guard writer.canAdd(input) else {
      throw EngineError.configuration("The iPhone could not create an H.264 video writer.")
    }
    writer.add(input)
  }

  func append(image: CIImage, timestamp: CMTime) throws {
    guard !finished else { return }
    guard timestamp.isValid, timestamp.isNumeric else { return }
    guard let presentationTime = timeline.presentationTime(for: timestamp) else { return }
    if writer.status == .unknown {
      guard writer.startWriting() else {
        throw writer.error ?? EngineError.configuration("Could not start amplified video recording.")
      }
      writer.startSession(atSourceTime: .zero)
      firstTimestamp = presentationTime
    }
    if writer.status == .failed {
      throw writer.error ?? EngineError.configuration("Amplified video recording failed.")
    }
    guard input.isReadyForMoreMediaData else { return }
    guard let pool = adaptor.pixelBufferPool else {
      throw EngineError.configuration("The video encoder did not provide a pixel buffer pool.")
    }
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else {
      throw EngineError.configuration("Could not allocate an amplified video frame.")
    }
    let bounds = CGRect(
      x: 0,
      y: 0,
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    ciContext.render(image, to: pixelBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
      throw writer.error ?? EngineError.configuration("Could not encode an amplified video frame.")
    }
    frameCount += 1
    lastTimestamp = presentationTime
  }

  func finish(completion: @escaping (Result<RecordingResult, Error>) -> Void) {
    guard !finished else {
      completion(.failure(EngineError.configuration("The video recording was already finalized.")))
      return
    }
    finished = true
    guard frameCount > 0, writer.status == .writing else {
      cancel()
      completion(.failure(EngineError.configuration("No amplified video frames were encoded.")))
      return
    }
    input.markAsFinished()
    writer.finishWriting { [writer, outputURL, firstTimestamp, lastTimestamp, frameCount] in
      if writer.status == .completed {
        let duration = if let firstTimestamp, let lastTimestamp {
          max(0, lastTimestamp.seconds - firstTimestamp.seconds)
        } else { 0.0 }
        completion(.success(RecordingResult(url: outputURL, durationSeconds: duration, frameCount: frameCount)))
      } else {
        completion(.failure(writer.error ?? EngineError.configuration("Could not finalize the amplified video.")))
      }
    }
  }

  func cancel() {
    if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    try? FileManager.default.removeItem(at: outputURL)
  }
}

struct RealTimeVideoTimeline {
  let maximumOutputFPS: Double
  private var firstSourceTimestamp: CMTime?
  private var lastPresentationTimestamp: CMTime?

  init(maximumOutputFPS: Double) {
    self.maximumOutputFPS = max(1, maximumOutputFPS)
  }

  mutating func presentationTime(for sourceTimestamp: CMTime) -> CMTime? {
    guard sourceTimestamp.isValid, sourceTimestamp.isNumeric else { return nil }
    guard let firstSourceTimestamp else {
      self.firstSourceTimestamp = sourceTimestamp
      lastPresentationTimestamp = .zero
      return .zero
    }

    let elapsed = CMTimeSubtract(sourceTimestamp, firstSourceTimestamp)
    guard elapsed.isValid, elapsed.isNumeric, CMTimeCompare(elapsed, .zero) > 0 else {
      return nil
    }
    if let lastPresentationTimestamp {
      let interval = CMTimeSubtract(elapsed, lastPresentationTimestamp)
      let minimumInterval = CMTime(
        seconds: 0.9 / maximumOutputFPS,
        preferredTimescale: 60_000
      )
      guard CMTimeCompare(interval, minimumInterval) >= 0 else { return nil }
    }
    lastPresentationTimestamp = elapsed
    return elapsed
  }
}

private struct FilterUniforms { var dt, lowerHz, upperHz, gain: Float; var reset, luminanceOnly: UInt32 }

private let amplificationKernelSource = #"""
#include <metal_stdlib>
using namespace metal;

struct FilterUniforms { float dt, lowerHz, upperHz, gain; uint reset, luminanceOnly; };

kernel void amplifyLuma(texture2d<float, access::read> input [[texture(0)]],
                        texture2d<float, access::read_write> fastState [[texture(1)]],
                        texture2d<float, access::read_write> slowState [[texture(2)]],
                        texture2d<float, access::write> output [[texture(3)]],
                        constant FilterUniforms &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
  const uint2 maxCoord = uint2(input.get_width() - 1, input.get_height() - 1);
  float4 original = input.read(gid);
  float4 spatial = original * 0.5;
  spatial += input.read(uint2(uint(max(int(gid.x)-1, 0)), gid.y)) * 0.125;
  spatial += input.read(uint2(min(gid.x+1, maxCoord.x), gid.y)) * 0.125;
  spatial += input.read(uint2(gid.x, uint(max(int(gid.y)-1, 0)))) * 0.125;
  spatial += input.read(uint2(gid.x, min(gid.y+1, maxCoord.y))) * 0.125;
  float luma = dot(spatial.rgb, float3(0.2126, 0.7152, 0.0722));
  float4 x = p.luminanceOnly != 0 ? float4(luma, luma, luma, original.a) : spatial;
  float4 fast = p.reset != 0 ? x : fastState.read(gid);
  float4 slow = p.reset != 0 ? x : slowState.read(gid);
  if (p.reset == 0 && p.dt > 0) {
    float fastAlpha = 1.0 - exp(-2.0 * M_PI_F * p.upperHz * p.dt);
    float slowAlpha = 1.0 - exp(-2.0 * M_PI_F * p.lowerHz * p.dt);
    fast += fastAlpha * (x - fast);
    slow += slowAlpha * (x - slow);
  }
  fastState.write(fast, gid);
  slowState.write(slow, gid);
  output.write(clamp(original + p.gain * (fast - slow), 0.0, 1.0), gid);
}
"""#

enum FrequencyEstimator {
  static func dominantFrequency(samples: [Float], timestamps: [Double], lowerHz: Double, upperHz: Double) -> Double {
    guard samples.count >= 32, let first = timestamps.first, let last = timestamps.last, last > first else { return 0 }
    let count = 1 << Int(floor(log2(Double(samples.count)))), rate = Double(count - 1) / (last - first); var signal = Array(samples.suffix(count)), window = [Float](repeating: 0, count: count); vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM)); vDSP_vmul(signal, 1, window, 1, &signal, 1, vDSP_Length(count))
    guard let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: count, direction: .forward, transformType: .complexComplex, ofType: Float.self) else { return 0 }; let zeros = [Float](repeating: 0, count: count); let spectrum = dft.transform(real: signal, imaginary: zeros); let real = spectrum.real, imag = spectrum.imaginary; var power = [Float](repeating: 0, count: count / 2); for index in power.indices { power[index] = real[index] * real[index] + imag[index] * imag[index] }
    let low = max(1, Int(ceil(lowerHz * Double(count) / rate))), high = min(power.count - 1, Int(floor(upperHz * Double(count) / rate))); guard high >= low else { return 0 }; let index = (low...high).max(by: { power[$0] < power[$1] }) ?? low; return Double(index) * rate / Double(count)
  }
}
