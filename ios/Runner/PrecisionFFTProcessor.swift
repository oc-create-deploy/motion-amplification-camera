import Accelerate
import AVFoundation
import CoreImage
import Darwin
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
  // A 64-pixel analysis edge is sufficient for the smooth, low-frequency
  // displacement field while cutting the two frame-major buffers by 56%
  // compared with build 12. The full-resolution ProRes image is still used
  // for reconstruction and export.
  static let gridLongEdge = 64
  // The source recorder emits at most 60 FPS. This upper bound permits the
  // full recommended 150 seconds for a 0.02 Hz band while keeping the two
  // frame-major analysis buffers within a practical mobile memory budget.
  static let maximumFrames = 9_300

  static func estimatedTimelineBytes(frameCount: Int, gridWidth: Int, gridHeight: Int) -> Int {
    // Both complete timelines are file-backed. Resident memory is bounded by
    // one temporal signal/spectrum and one analysis frame, independent of the
    // recording duration.
    let fftCount = 1 << Int(ceil(log2(Double(max(16, frameCount)))))
    return fftCount * MemoryLayout<Float>.stride * 6
      + gridWidth * gridHeight * MemoryLayout<UInt8>.stride
  }

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
      var filteredURL: URL?
      do {
        progress(0.01)
        // Keep source luma inside this helper so Swift can release it before
        // full-resolution decode and Metal reconstruction begin.
        let timeline = try self.makeFilteredTimeline(
          sourceURL: sourceURL,
          lowerHz: lowerHz,
          upperHz: upperHz,
          readProgress: { progress(0.02 + 0.18 * $0) },
          filterProgress: { progress(0.20 + 0.48 * $0) }
        )
        filteredURL = timeline.url
        try self.renderFilteredVideo(
          sourceURL: sourceURL,
          filteredURL: timeline.url,
          frameCount: timeline.frameCount,
          gridWidth: timeline.gridWidth,
          gridHeight: timeline.gridHeight,
          gain: gain,
          expectedFPS: timeline.sampleRate,
          progress: { progress(0.68 + 0.31 * $0) },
          completion: { result in
            try? FileManager.default.removeItem(at: timeline.url)
            progress(1)
            completion(result)
          }
        )
      } catch {
        if let filteredURL { try? FileManager.default.removeItem(at: filteredURL) }
        completion(.failure(error))
      }
    }
  }

  private struct LuminanceTimeline {
    let url: URL
    let timestamps: [Double]
    let gridWidth: Int
    let gridHeight: Int
    let sampleRate: Double
  }

  private struct FilteredTimeline {
    let url: URL
    let frameCount: Int
    let gridWidth: Int
    let gridHeight: Int
    let sampleRate: Double
  }

  private func makeFilteredTimeline(
    sourceURL: URL,
    lowerHz: Double,
    upperHz: Double,
    readProgress: (Double) -> Void,
    filterProgress: (Double) -> Void
  ) throws -> FilteredTimeline {
    let analysis = try readLuminanceTimeline(
      sourceURL: sourceURL,
      progress: readProgress
    )
    let frameCount = analysis.timestamps.count
    let filteredURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("precision-fft-filtered-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: analysis.url) }
    try PrecisionFFTBandpass.filterPixels(
      frameMajorLumaURL: analysis.url,
      filteredURL: filteredURL,
      frameCount: frameCount,
      pixelCount: analysis.gridWidth * analysis.gridHeight,
      sampleRate: analysis.sampleRate,
      lowerHz: lowerHz,
      upperHz: upperHz,
      progress: filterProgress
    )
    return FilteredTimeline(
      url: filteredURL,
      frameCount: frameCount,
      gridWidth: analysis.gridWidth,
      gridHeight: analysis.gridHeight,
      sampleRate: analysis.sampleRate
    )
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
    let lumaURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("precision-fft-luma-\(UUID().uuidString).bin")
    guard FileManager.default.createFile(atPath: lumaURL.path, contents: nil) else {
      throw EngineError.configuration("Precision FFT could not create its temporary timeline.")
    }
    var completed = false
    defer {
      if !completed { try? FileManager.default.removeItem(at: lumaURL) }
    }
    let lumaHandle = try FileHandle(forWritingTo: lumaURL)
    defer { try? lumaHandle.close() }
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
      var timestamp: Double?
      try autoreleasepool {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { return }
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
        }
        guard let scratch else { return }
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
        var frame = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        CVPixelBufferLockBaseAddress(scratch, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(scratch, .readOnly) }
        if let base = CVPixelBufferGetBaseAddress(scratch) {
          let stride = CVPixelBufferGetBytesPerRow(scratch)
          for y in 0..<gridHeight {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<gridWidth {
              let blue = Float(row[x * 4])
              let green = Float(row[x * 4 + 1])
              let red = Float(row[x * 4 + 2])
              frame[y * gridWidth + x] = UInt8(
                clamping: Int((0.0722 * blue + 0.7152 * green + 0.2126 * red).rounded())
              )
            }
          }
        }
        try lumaHandle.write(contentsOf: frame)
        timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      }
      if let timestamp { timestamps.append(timestamp) }
      if timestamps.count % 120 == 0 {
        ciContext.clearCaches()
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
    completed = true
    return LuminanceTimeline(
      url: lumaURL,
      timestamps: timestamps,
      gridWidth: gridWidth,
      gridHeight: gridHeight,
      sampleRate: sampleRate
    )
  }

  private func renderFilteredVideo(
    sourceURL: URL,
    filteredURL: URL,
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
    let filteredMap = try MappedTimeline(
      url: filteredURL,
      byteCount: frameCount * gridWidth * gridHeight * MemoryLayout<UInt16>.stride,
      writable: false
    )
    let filteredBits = filteredMap.pointer.assumingMemoryBound(to: UInt16.self)
    let bandDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r16Float,
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
          bandTexture.replace(
            region: MTLRegionMake2D(0, 0, gridWidth, gridHeight),
            mipmapLevel: 0,
            withBytes: filteredBits.advanced(by: offset),
            bytesPerRow: gridWidth * MemoryLayout<UInt16>.stride
          )
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
    frameMajorLumaURL: URL,
    filteredURL: URL,
    frameCount: Int,
    pixelCount: Int,
    sampleRate: Double,
    lowerHz: Double,
    upperHz: Double,
    progress: (Double) -> Void = { _ in }
  ) throws {
    let inputBytes = frameCount * pixelCount
    let outputBytes = inputBytes * MemoryLayout<UInt16>.stride
    let input = try MappedTimeline(url: frameMajorLumaURL, byteCount: inputBytes, writable: false)
    let output = try MappedTimeline(url: filteredURL, byteCount: outputBytes, writable: true)
    let source = input.pointer.assumingMemoryBound(to: UInt8.self)
    let destination = output.pointer.assumingMemoryBound(to: UInt16.self)
    try filterPixels(
      frameCount: frameCount,
      pixelCount: pixelCount,
      sampleRate: sampleRate,
      lowerHz: lowerHz,
      upperHz: upperHz,
      progress: progress,
      sample: { source[$0 * pixelCount + $1] },
      store: { destination[$0 * pixelCount + $1] = $2.bitPattern }
    )
  }

  static func filterPixels(
    frameMajorLuma: [UInt8],
    frameCount: Int,
    pixelCount: Int,
    sampleRate: Double,
    lowerHz: Double,
    upperHz: Double,
    progress: (Double) -> Void = { _ in }
  ) throws -> [Float16] {
    guard frameMajorLuma.count == frameCount * pixelCount else {
      throw EngineError.configuration("Precision FFT received invalid temporal data.")
    }
    var filtered = [Float16](repeating: 0, count: frameCount * pixelCount)
    try filterPixels(
      frameCount: frameCount,
      pixelCount: pixelCount,
      sampleRate: sampleRate,
      lowerHz: lowerHz,
      upperHz: upperHz,
      progress: progress,
      sample: { frameMajorLuma[$0 * pixelCount + $1] },
      store: { filtered[$0 * pixelCount + $1] = $2 }
    )
    return filtered
  }

  private static func filterPixels(
    frameCount: Int,
    pixelCount: Int,
    sampleRate: Double,
    lowerHz: Double,
    upperHz: Double,
    progress: (Double) -> Void,
    sample: (Int, Int) -> UInt8,
    store: (Int, Int, Float16) -> Void
  ) throws {
    guard frameCount >= 16, pixelCount > 0, sampleRate > 0,
          lowerHz > 0, upperHz > lowerHz else {
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
    var signal = [Float](repeating: 0, count: fftCount)

    for pixel in 0..<pixelCount {
      var mean: Float = 0
      for frame in 0..<frameCount {
        let value = Float(sample(frame, pixel)) / 255
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
        store(frame, pixel, Float16(temporal.real[frame] * scale))
      }
      if pixel % 32 == 0 { progress(Double(pixel) / Double(pixelCount)) }
    }
    progress(1)
  }
}

private final class MappedTimeline {
  let pointer: UnsafeMutableRawPointer
  private let byteCount: Int
  private let descriptor: Int32

  init(url: URL, byteCount: Int, writable: Bool) throws {
    self.byteCount = byteCount
    let flags = writable ? (O_RDWR | O_CREAT | O_TRUNC) : O_RDONLY
    descriptor = open(url.path, flags, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw EngineError.configuration("Precision FFT could not open its temporary timeline.")
    }
    if writable, ftruncate(descriptor, off_t(byteCount)) != 0 {
      close(descriptor)
      throw EngineError.configuration("Precision FFT could not size its temporary timeline.")
    }
    let protection = writable ? (PROT_READ | PROT_WRITE) : PROT_READ
    guard let mapped = mmap(nil, byteCount, protection, MAP_SHARED, descriptor, 0),
          mapped != MAP_FAILED else {
      close(descriptor)
      throw EngineError.configuration("Precision FFT could not map its temporary timeline.")
    }
    pointer = mapped
  }

  deinit {
    msync(pointer, byteCount, MS_ASYNC)
    munmap(pointer, byteCount)
    close(descriptor)
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
