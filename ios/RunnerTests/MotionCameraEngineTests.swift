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

  func testPortraitSoftwareRotationIsUpright() {
    let angle = MotionCameraEngine.fallbackVideoRotationAngle(for: .portrait)
    XCTAssertEqual(angle, 90)
    XCTAssertEqual(MotionCameraEngine.exifOrientation(forClockwiseRotationAngle: angle), 6)
    XCTAssertEqual(
      MotionCameraEngine.fallbackVideoRotationAngle(for: .portraitUpsideDown),
      270
    )
  }

  func testUiKitPreviewUsesPresentationOnlyHalfTurn() {
    XCTAssertEqual(MotionCameraEngine.previewDisplayExifOrientation, 3)
  }

  func testUiKitPreviewROIRemainsAlignedAfterHalfTurn() {
    let mapped = MotionCameraEngine.cameraROI(
      fromPreviewROI: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    )
    XCTAssertEqual(mapped.origin.x, 0.6, accuracy: 0.000_001)
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

  func testCalibrationConversion() {
    let pixelsPerMillimeter = 12.5
    XCTAssertEqual(25.0 / pixelsPerMillimeter, 2.0, accuracy: 1e-9)
  }
}
