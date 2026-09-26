import AVFoundation
import Metal
import XCTest
@testable import Runner

final class MotionCameraEngineTests: XCTestCase {
  func testAmplificationPipelineLoads() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal is unavailable on this test destination")
    }
    XCTAssertTrue(MotionCameraEngine().isAmplificationPipelineReadyForTesting)
  }

  func testTemporalStatePreservesSubPixelPrecision() {
    XCTAssertEqual(MotionCameraEngine.temporalStatePixelFormatForTesting, .r32Float)
  }

  func testApplicationDeclaresPortraitOnly() {
    let orientations = Bundle.main.object(
      forInfoDictionaryKey: "UISupportedInterfaceOrientations"
    ) as? [String]
    XCTAssertEqual(orientations, ["UIInterfaceOrientationPortrait"])
  }

  func testPortraitSoftwareRotationIsUpright() {
    let angle = MotionCameraEngine.fallbackVideoRotationAngle(for: .portrait)
    XCTAssertEqual(angle, 90)
    XCTAssertEqual(MotionCameraEngine.exifOrientation(forClockwiseRotationAngle: angle), 6)
    XCTAssertEqual(
      MotionCameraEngine.fallbackVideoRotationAngle(for: .portraitUpsideDown),
      270
    )
  }

  func testUiKitPreviewUsesPresentationOnlyVerticalFlip() {
    let transform = MotionCameraEngine.previewDisplayTransform(
      for: CGRect(x: 0, y: 0, width: 720, height: 1280)
    )
    XCTAssertEqual(transform.a, 1, accuracy: 0.000_001)
    XCTAssertEqual(transform.d, -1, accuracy: 0.000_001)
    XCTAssertEqual(transform.tx, 0, accuracy: 0.000_001)
    XCTAssertEqual(transform.ty, 1280, accuracy: 0.000_001)
  }

  func testUiKitPreviewROIRemainsAlignedAfterVerticalFlip() {
    let mapped = MotionCameraEngine.cameraROI(
      fromPreviewROI: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    )
    XCTAssertEqual(mapped.origin.x, 0.1, accuracy: 0.000_001)
    XCTAssertEqual(mapped.origin.y, 0.4, accuracy: 0.000_001)
    XCTAssertEqual(mapped.width, 0.3, accuracy: 0.000_001)
    XCTAssertEqual(mapped.height, 0.4, accuracy: 0.000_001)
  }

  func testTimestampCoefficientMatchesReference() {
    let fc = 8.0, dt = 1.0 / 60.0
    let alpha = 1.0 - exp(-2.0 * Double.pi * fc * dt)
    XCTAssertEqual(alpha, 0.566, accuracy: 0.002)
  }

  func testHighSpeedCaptureExportsAtRealTimeSixtyFPS() {
    var timeline = RealTimeVideoTimeline(maximumOutputFPS: 60)
    let presentationTimes = (0...120).compactMap { frame in
      timeline.presentationTime(for: CMTime(value: CMTimeValue(frame), timescale: 120))
    }

    XCTAssertEqual(presentationTimes.count, 61)
    XCTAssertEqual(presentationTimes.first?.seconds ?? -1, 0)
    XCTAssertEqual(presentationTimes.last?.seconds ?? -1, 1, accuracy: 0.000_001)
  }

  func testRecorderUsesHighFidelityProResWithoutCompressionProperties() {
    let settings = AmplifiedVideoRecorder.videoSettings(width: 1280, height: 720)

    XCTAssertEqual(
      settings[AVVideoCodecKey] as? AVVideoCodecType,
      AVVideoCodecType.proRes4444
    )
    XCTAssertNil(settings[AVVideoCompressionPropertiesKey])
    XCTAssertEqual(AmplifiedVideoRecorder.outputFileType, .mov)
    XCTAssertEqual(AmplifiedVideoRecorder.outputFileExtension, "mov")
  }

  func testSyntheticFrequencyDetection() {
    let fps = 60.0, target = 5.0, count = 256
    let times = (0..<count).map { Double($0) / fps }
    let samples = times.map { Float(sin(2 * Double.pi * target * $0)) }
    let detected = FrequencyEstimator.dominantFrequency(samples: samples, timestamps: times, lowerHz: 1, upperHz: 10)
    XCTAssertEqual(detected, target, accuracy: fps / Double(count))
  }

  func testPrecisionFFTBandpassRetainsSelectedFrequency() throws {
    let sampleRate = 64.0
    let frameCount = 256
    let pixelCount = 2
    var samples = [UInt8](repeating: 0, count: frameCount * pixelCount)
    for frame in 0..<frameCount {
      let time = Double(frame) / sampleRate
      let inBand = 128 + 80 * sin(2 * Double.pi * 5 * time)
      let outOfBand = 128 + 80 * sin(2 * Double.pi * 15 * time)
      samples[frame * pixelCount] = UInt8(clamping: Int(inBand.rounded()))
      samples[frame * pixelCount + 1] = UInt8(clamping: Int(outOfBand.rounded()))
    }

    let filtered = try PrecisionFFTBandpass.filterPixels(
      frameMajorLuma: samples,
      frameCount: frameCount,
      pixelCount: pixelCount,
      sampleRate: sampleRate,
      lowerHz: 4,
      upperHz: 6
    )
    let inBandRMS = sqrt(
      (0..<frameCount).map { pow(Double(filtered[$0 * pixelCount]), 2) }.reduce(0, +)
        / Double(frameCount)
    )
    let outOfBandRMS = sqrt(
      (0..<frameCount).map { pow(Double(filtered[$0 * pixelCount + 1]), 2) }.reduce(0, +)
        / Double(frameCount)
    )

    XCTAssertGreaterThan(inBandRMS, 0.1)
    XCTAssertGreaterThan(inBandRMS, outOfBandRMS * 8)
  }

  func testPrecisionFFTWorstCaseTimelineStaysMemoryBounded() {
    let width = 36
    let height = PrecisionFFTProcessor.gridLongEdge
    let bytes = PrecisionFFTProcessor.estimatedTimelineBytes(
      frameCount: PrecisionFFTProcessor.maximumFrames,
      gridWidth: width,
      gridHeight: height
    )

    XCTAssertEqual(PrecisionFFTProcessor.gridLongEdge, 64)
    XCTAssertLessThan(bytes, 1 * 1_024 * 1_024)
  }

  func testPrecisionFFTFileBackedTimelineSelectsBand() throws {
    let sampleRate = 64.0
    let frameCount = 256
    let pixelCount = 2
    var samples = [UInt8](repeating: 0, count: frameCount * pixelCount)
    for frame in 0..<frameCount {
      let time = Double(frame) / sampleRate
      samples[frame * pixelCount] = UInt8(
        clamping: Int((128 + 80 * sin(2 * Double.pi * 5 * time)).rounded())
      )
      samples[frame * pixelCount + 1] = UInt8(
        clamping: Int((128 + 80 * sin(2 * Double.pi * 15 * time)).rounded())
      )
    }
    let directory = FileManager.default.temporaryDirectory
    let input = directory.appendingPathComponent("precision-test-\(UUID().uuidString).luma")
    let output = directory.appendingPathComponent("precision-test-\(UUID().uuidString).band")
    defer {
      try? FileManager.default.removeItem(at: input)
      try? FileManager.default.removeItem(at: output)
    }
    try Data(samples).write(to: input)
    try PrecisionFFTBandpass.filterPixels(
      frameMajorLumaURL: input,
      filteredURL: output,
      frameCount: frameCount,
      pixelCount: pixelCount,
      sampleRate: sampleRate,
      lowerHz: 4,
      upperHz: 6
    )
    let data = try Data(contentsOf: output)
    let values = data.withUnsafeBytes { bytes -> [Float16] in
      Array(bytes.bindMemory(to: UInt16.self)).map(Float16.init(bitPattern:))
    }
    let inBandRMS = sqrt(
      (0..<frameCount).map { pow(Double(values[$0 * pixelCount]), 2) }.reduce(0, +)
        / Double(frameCount)
    )
    let outOfBandRMS = sqrt(
      (0..<frameCount).map { pow(Double(values[$0 * pixelCount + 1]), 2) }.reduce(0, +)
        / Double(frameCount)
    )
    XCTAssertGreaterThan(inBandRMS, outOfBandRMS * 8)
  }

  func testCalibrationConversion() {
    let pixelsPerMillimeter = 12.5
    XCTAssertEqual(25.0 / pixelsPerMillimeter, 2.0, accuracy: 1e-9)
  }
}
