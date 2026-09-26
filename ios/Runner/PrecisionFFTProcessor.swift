import Accelerate
import AVFoundation
import CoreImage
import Metal

/// Offline, zero-phase temporal processing for saved inspection video.
///
/// The live camera path stays responsive and timestamp-aware. In Precision
/// FFT mode, the unamplified ProRes source is retained temporarily, reduced to
/// a small luminance pyramid level, filtered across the complete recording,
/// and then used as a displacement field while the full-resolution source is
/// decoded a second time. This is the mobile-native equivalent of the batch
/// FFT idea used by classic Eulerian video magnification implementations.
final class PrecisionFFTProcessor {
  static let gridLongEdge = 96
  // The source recorder emits at most 60 FPS. This upper bound permits the
  // full recommended 150 seconds for a 0.02 Hz band while keeping the two
  // frame-major analysis buffers within a practical mobile memory budget.
  static let maximumFrames = 9_300

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let ciContext: CIContext
  private var textureCache: CVMetalTextureCache?
  private let pipeline: MTLComputePipelineState

  init(device: MTLDevice, commandQueue: MTLCommandQueue, ciContext: CIContext) throws {
    self.device = device
    self.commandQueue = commandQueue
    self.ciContext = ciContext
    CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    guard let library = try? device.makeLibrary(source: precisionFFTKernelSource, options: nil),
          let function = library.makeFunction(name: "precisionFFTAmplify"),
          let pipeline = try? device.makeComputePipelineState(function: function) else {
      throw EngineError.configuration("The Precision FFT Metal pipeline could not be created.")
    }
    self.pipeline = pipeline
  }

  func process(
    sourceURL: URL,
    lowerHz: Double,
    upperHz: Double,
    gain: Double,
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<RecordingResult, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        progress(0.01)
        let analysis = try self.readLuminanceTimeline(
          sourceURL: sourceURL,
          progress: { progress(0.02 + 0.18 * $0) }
        )
        let filtered = try PrecisionFFTBandpass.filterPixels(
          frameMajorLuma: analysis.luma,
          frameCount: analysis.timestamps.count,
          pixelCount: analysis.gridWidth * analysis.gridHeight,
          sampleRate: analysis.sampleRate,
          lowerHz: lowerHz,
          upperHz: upperHz,
          progress: { progress(0.20 + 0.48 * $0) }
        )
        try self.renderFilteredVideo(
          sourceURL: sourceURL,
          filteredFrameMajor: filtered,
          frameCount: analysis.timestamps.count,
          gridWidth: analysis.gridWidth,
          gridHeight: analysis.gridHeight,
          gain: gain,
          expectedFPS: analysis.sampleRate,
          progress: { progress(0.68 + 0.31 * $0) },
          completion: { result in
            progress(1)
            completion(result)
          }
        )
      } catch {
        completion(.failure(error))
      }
    }
  }

  private struct LuminanceTimeline {
    let luma: [UInt8]
    let timestamps: [Double]
    let gridWidth: Int
    let gridHeight: Int
    let sampleRate: Double
  }

  private func makeReader(url: URL) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw EngineError.configuration("The precision source video has no video track.")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw EngineError.configuration("The precision source video cannot be decoded.")
    }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? EngineError.configuration("The precision source video could not be opened.")
    }
    return (reader, output)
  }

  private func readLuminanceTimeline(
    sourceURL: URL,
    progress: (Double) -> Void
  ) throws -> LuminanceTimeline {
    let (reader, output) = try makeReader(url: sourceURL)
    var luma = [UInt8]()
    var timestamps = [Double]()
    var gridWidth = 0
    var gridHeight = 0
    var scratch: CVPixelBuffer?

    while let sample = output.copyNextSampleBuffer() {
      if timestamps.count >= Self.maximumFrames {
        throw EngineError.configuration(
          "Precision FFT supports recordings up to about 150 seconds. Shorten the recording or use Live mode."
        )
      }
      guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
      if scratch == nil {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if width >= height {
          gridWidth = Self.gridLongEdge
          gridHeight = max(1, Int((Double(height) / Double(width) * Double(gridWidth)).rounded()))
        } else {
          gridHeight = Self.gridLongEdge
          gridWidth = max(1, Int((Double(width) / Double(height) * Double(gridHeight)).rounded()))
        }
        let attributes: [String: Any] = [
          kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(
          nil,
          gridWidth,
          gridHeight,
          kCVPixelFormatType_32BGRA,
          attributes as CFDictionary,
          &scratch
        ) == kCVReturnSuccess else {
          throw EngineError.configuration("Precision FFT could not allocate its analysis buffer.")
        }
        luma.reserveCapacity(Self.maximumFrames * gridWidth * gridHeight)
      }
      guard let scratch else { continue }
      let sourceImage = CIImage(cvPixelBuffer: source)
      let transform = CGAffineTransform(
        scaleX: CGFloat(gridWidth) / sourceImage.extent.width,
        y: CGFloat(gridHeight) / sourceImage.extent.height
      ).translatedBy(x: -sourceImage.extent.minX, y: -sourceImage.extent.minY)
      ciContext.render(
        sourceImage.transformed(by: transform),
        to: scratch,
        bounds: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight),
        colorSpace: CGColorSpaceCreateDeviceRGB()
      )
      CVPixelBufferLockBaseAddress(scratch, .readOnly)
      if let base = CVPixelBufferGetBaseAddress(scratch) {
        let stride = CVPixelBufferGetBytesPerRow(scratch)
        for y in 0..<gridHeight {
          let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
          for x in 0..<gridWidth {
            let blue = Float(row[x * 4])
            let green = Float(row[x * 4 + 1])
            let red = Float(row[x * 4 + 2])
            luma.append(UInt8(clamping: Int((0.0722 * blue + 0.7152 * green + 0.2126 * red).rounded())))
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(scratch, .readOnly)
      timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
      if timestamps.count % 120 == 0 {
        progress(min(0.98, Double(timestamps.count) / 9_000.0))
      }
    }
    if reader.status == .failed {
      throw reader.error ?? EngineError.configuration("Precision FFT could not decode the source video.")
    }
    guard timestamps.count >= 16, gridWidth > 0, gridHeight > 0 else {
      throw EngineError.configuration("Precision FFT needs at least 16 recorded frames.")
    }
    let duration = max(0.001, (timestamps.last ?? 0) - (timestamps.first ?? 0))
    let sampleRate = Double(timestamps.count - 1) / duration
    return LuminanceTimeline(
      luma: luma,
      timestamps: timestamps,
      gridWidth: gridWidth,
      gridHeight: gridHeight,
      sampleRate: sampleRate
    )
  }

  private func renderFilteredVideo(
    sourceURL: URL,
    filteredFrameMajor: [Float16],
    frameCount: Int,
    gridWidth: Int,
    gridHeight: Int,
    gain: Double,
    expectedFPS: Double,
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<RecordingResult, Error>) -> Void
  ) throws {
    guard let cache = textureCache else {
      throw EngineError.configuration("Precision FFT cannot access the Metal texture cache.")
    }
    let (reader, output) = try makeReader(url: sourceURL)
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("precision-fft-amplified-\(UUID().uuidString).mov")
    var recorder: AmplifiedVideoRecorder?
    var outputTexture: MTLTexture?
    let bandDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r32Float,
      width: gridWidth,
      height: gridHeight,
      mipmapped: false
    )
    bandDescriptor.usage = [.shaderRead]
    guard let bandTexture = device.makeTexture(descriptor: bandDescriptor) else {
      throw EngineError.configuration("Precision FFT could not allocate its spectral texture.")
    }
    var frameIndex = 0
    do {
      while frameIndex < frameCount, let sample = output.copyNextSampleBuffer() {
        try autoreleasepool {
          guard let source = CMSampleBufferGetImageBuffer(sample) else { return }
          let width = CVPixelBufferGetWidth(source)
          let height = CVPixelBufferGetHeight(source)
          if recorder == nil {
            recorder = try AmplifiedVideoRecorder(
              outputURL: destinationURL,
              width: width,
              height: height,
              expectedFPS: expectedFPS,
              ciContext: ciContext,
              expectsMediaDataInRealTime: false
            )
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
              pixelFormat: .bgra8Unorm,
              width: width,
              height: height,
              mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            outputTexture = device.makeTexture(descriptor: descriptor)
          }
          guard let outputTexture else {
            throw EngineError.configuration("Precision FFT could not allocate its output texture.")
          }
          var sourceCVTexture: CVMetalTexture?
          guard CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            source,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &sourceCVTexture
          ) == kCVReturnSuccess,
          let sourceTexture = sourceCVTexture.flatMap(CVMetalTextureGetTexture) else {
            throw EngineError.configuration("Precision FFT could not map a source frame to Metal.")
          }
          let offset = frameIndex * gridWidth * gridHeight
          var band = [Float](repeating: 0, count: gridWidth * gridHeight)
          for pixel in band.indices {
            band[pixel] = Float(filteredFrameMajor[offset + pixel])
          }
          band.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
              bandTexture.replace(
                region: MTLRegionMake2D(0, 0, gridWidth, gridHeight),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: gridWidth * MemoryLayout<Float>.stride
              )
            }
          }
          guard let command = commandQueue.makeCommandBuffer(),
                let encoder = command.makeComputeCommandEncoder() else {
            throw EngineError.configuration("Precision FFT could not create a Metal command.")
          }
          encoder.setComputePipelineState(pipeline)
          encoder.setTexture(sourceTexture, index: 0)
          encoder.setTexture(bandTexture, index: 1)
          encoder.setTexture(outputTexture, index: 2)
          var uniforms = PrecisionFFTUniforms(gain: Float(gain))
          encoder.setBytes(&uniforms, length: MemoryLayout<PrecisionFFTUniforms>.stride, index: 0)
          let threads = MTLSize(width: 16, height: 16, depth: 1)
          encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: threads
          )
          encoder.endEncoding()
          command.commit()
          command.waitUntilCompleted()
          guard command.status == .completed,
                let image = CIImage(
                  mtlTexture: outputTexture,
                  options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]
                ) else {
            throw command.error ?? EngineError.configuration("Precision FFT failed to render a frame.")
          }
          try recorder?.append(
            image: image,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sample)
          )
        }
        frameIndex += 1
        if frameIndex % 30 == 0 {
          progress(Double(frameIndex) / Double(frameCount))
        }
      }
      if reader.status == .failed {
        throw reader.error ?? EngineError.configuration(
          "Precision FFT could not decode the source during reconstruction."
        )
      }
      guard frameIndex == frameCount, let recorder else {
        throw EngineError.configuration("Precision FFT could not reconstruct every recorded frame.")
      }
      recorder.finish(completion: completion)
    } catch {
      recorder?.cancel()
      try? FileManager.default.removeItem(at: destinationURL)
      throw error
    }
  }
}

enum PrecisionFFTBandpass {
  static func filterPixels(
    frameMajorLuma: [UInt8],
    frameCount: Int,
    pixelCount: Int,
    sampleRate: Double,
    lowerHz: Double,
    upperHz: Double,
    progress: (Double) -> Void = { _ in }
  ) throws -> [Float16] {
    guard frameCount >= 16,
          pixelCount > 0,
          frameMajorLuma.count == frameCount * pixelCount,
          sampleRate > 0,
          lowerHz > 0,
          upperHz > lowerHz else {
      throw EngineError.configuration("Precision FFT received invalid temporal data.")
    }
    let fftCount = 1 << Int(ceil(log2(Double(frameCount))))
    guard let forward = try? vDSP.DiscreteFourierTransform(
      previous: nil,
      count: fftCount,
      direction: .forward,
      transformType: .complexComplex,
      ofType: Float.self
    ),
    let inverse = try? vDSP.DiscreteFourierTransform(
      previous: nil,
      count: fftCount,
      direction: .inverse,
      transformType: .complexComplex,
      ofType: Float.self
    ) else {
      throw EngineError.configuration("Precision FFT could not create its temporal transform.")
    }
    let zeros = [Float](repeating: 0, count: fftCount)
    var filtered = [Float16](repeating: 0, count: frameCount * pixelCount)
    var signal = [Float](repeating: 0, count: fftCount)

    for pixel in 0..<pixelCount {
      var mean: Float = 0
      for frame in 0..<frameCount {
        let value = Float(frameMajorLuma[frame * pixelCount + pixel]) / 255
        signal[frame] = value
        mean += value
      }
      mean /= Float(frameCount)
      for frame in 0..<frameCount { signal[frame] -= mean }
      if frameCount < fftCount {
        signal.replaceSubrange(frameCount..<fftCount, with: repeatElement(0, count: fftCount - frameCount))
      }
      var spectrum = forward.transform(real: signal, imaginary: zeros)
      for bin in 0..<fftCount {
        let foldedBin = min(bin, fftCount - bin)
        let frequency = Double(foldedBin) * sampleRate / Double(fftCount)
        if frequency < lowerHz || frequency > upperHz {
          spectrum.real[bin] = 0
          spectrum.imaginary[bin] = 0
        }
      }
      let temporal = inverse.transform(real: spectrum.real, imaginary: spectrum.imaginary)
      let scale = 1 / Float(fftCount)
      for frame in 0..<frameCount {
        filtered[frame * pixelCount + pixel] = Float16(temporal.real[frame] * scale)
      }
      if pixel % 32 == 0 { progress(Double(pixel) / Double(pixelCount)) }
    }
    progress(1)
    return filtered
  }
}

private struct PrecisionFFTUniforms { var gain: Float }

private let precisionFFTKernelSource = #"""
#include <metal_stdlib>
using namespace metal;

struct PrecisionFFTUniforms { float gain; };
inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

kernel void precisionFFTAmplify(
  texture2d<float, access::sample> source [[texture(0)]],
  texture2d<float, access::sample> temporalBand [[texture(1)]],
  texture2d<float, access::write> output [[texture(2)]],
  constant PrecisionFFTUniforms &p [[buffer(0)]],
  uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
  constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
  float2 size = float2(source.get_width(), source.get_height());
  float2 texel = 1.0 / size;
  float2 uv = (float2(gid) + 0.5) * texel;
  float gx = 0.5 * (luma(source.sample(linearSampler, uv + float2(texel.x, 0)).rgb)
                  - luma(source.sample(linearSampler, uv - float2(texel.x, 0)).rgb));
  float gy = 0.5 * (luma(source.sample(linearSampler, uv + float2(0, texel.y)).rgb)
                  - luma(source.sample(linearSampler, uv - float2(0, texel.y)).rgb));
  float2 gradient = float2(gx, gy);
  float energy = dot(gradient, gradient);
  float confidence = smoothstep(0.000015, 0.0025, energy);
  float band = temporalBand.sample(linearSampler, uv).r;
  float2 displacement = -band * gradient / max(energy, 0.000015);
  float2 amplified = clamp(displacement * p.gain * confidence, float2(-40.0), float2(40.0));
  output.write(clamp(source.sample(linearSampler, uv - amplified * texel), 0.0, 1.0), gid);
}
"""#
