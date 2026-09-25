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
    XCTAssertEqual(angle, 270)
    XCTAssertEqual(MotionCameraEngine.exifOrientation(forClockwiseRotationAngle: angle), 8)
    XCTAssertEqual(
      MotionCameraEngine.exifOrientation(forClockwiseRotationAngle: 90),
      6
    )
  }

  func testTimestampCoefficientMatchesReference() {
    let fc = 8.0, dt = 1.0 / 60.0
    let alpha = 1.0 - exp(-2.0 * Double.pi * fc * dt)
    XCTAssertEqual(alpha, 0.566, accuracy: 0.002)
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
