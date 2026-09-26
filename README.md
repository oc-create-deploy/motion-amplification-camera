# Motion Amplification Camera

An iPhone-only Flutter application that visualizes subtle periodic structural motion and reports translation inside a selected region of interest (ROI). Version `1.0.0+1`, bundle ID `com.industrial.motionamplification`.

> **Inspection support only.** This app is not a certified safety instrument, a metrology-grade system, or a replacement for calibrated accelerometers, displacement sensors, engineering review, or safe-work procedures.

## What works in v1

- Live rear-camera preview plus optional whole-recording Precision FFT post-processing.
- Best supported format negotiation, preferring a bounded 720p/120 FPS mode and automatically falling back to bounded 1080p/60 FPS when the camera does not support 120 FPS. The UI reports measured—not assumed—FPS.
- Apple ProRes 4444 MOV export capped at 60 FPS, so 120 FPS analysis footage is not saved as slow motion.
- Start/stop analysis beside the preview, touch-drag ROI, gain/band controls, luma/color modes, three processing quality settings, torch, exposure compensation, and focus/exposure/white-balance locks.
- ROI translation in pixels, RMS/peak displacement, dominant frequency, confidence, compact history chart, and explicit warnings.
- Known-length calibration stored locally; millimeters never appear unless calibration is valid.
- Precision FFT mode records an unamplified ProRes source, applies a zero-phase temporal FFT band-pass across the complete recording, and uses the filtered low-resolution signal to warp the full-resolution source into the final ProRes 4444 MOV. Live mode records the real-time Metal output directly.
- Frequency-aware guidance recommends at least two cycles and preferably three; for 0.02 Hz, that is 100 seconds minimum and 150 seconds recommended.
- Processed still snapshots and amplified videos are saved to Photos only after explicit user action and add-only permission.
- Safety onboarding, accessibility semantics, Dynamic Type-friendly scrolling, dark industrial theme, privacy/about/limitations content.

## Architecture

```text
Flutter Material 3 UI
  ├─ Method/Event channels (settings, controls, low-rate measurements)
  └─ UiKitView → MTKView
       └─ Swift MotionCameraEngine
          ├─ AVFoundation capture + real CMSampleBuffer timestamps
          ├─ Metal spatial smoothing + temporal amplification + reliable MTKView display
          ├─ AVAssetWriter ProRes 4444 capture and export
          ├─ Accelerate/vDSP whole-recording temporal FFT band-pass
          ├─ Metal full-resolution reconstruction from the spectral motion signal
          ├─ Vision ROI translation registration
          └─ Accelerate/vDSP Hann-windowed FFT and statistics
```

Full camera frames never cross into Dart. Metal handles the full-frame image path, while Flutter receives compact measurement/status maps plus the finalized local MOV path. Vision and vDSP operate natively. Camera session work and frame processing use dedicated serial queues. Camera authorization is requested before capture configuration, and the MTKView delegate draws processed frames on the UI thread rather than acquiring drawables from the capture callback.

## Algorithm

For each spatially filtered luma sample `x(t)`, two first-order low-pass states use the actual frame interval `dt`:

```text
alpha(fc, dt) = 1 - exp(-2π fc dt)
fast(t) = fast(t-1) + alpha(upperHz, dt) × (x(t) - fast(t-1))
slow(t) = slow(t-1) + alpha(lowerHz, dt) × (x(t) - slow(t-1))
band(t) = fast(t) - slow(t)
output(t) = clamp(input(t) + gain × band(t), 0, 1)
```

There are no frame-count-dependent filter constants. The Metal shader applies a five-tap spatial pyramid base approximation before the temporal stage, reconstructs onto the incoming frame, and clamps output. Filter state resets after ROI/configuration changes, orientation/format changes (through reconfiguration), and timestamp discontinuities.

The engine constrains `upperHz < 0.45 × measuredFPS`, leaving margin below Nyquist. Vision translational registration is limited to the ROI. A rolling timestamped displacement history feeds a Hann-windowed real-to-complex vDSP DFT; only bins inside the requested band are considered.

## Calibration

1. Mount the iPhone rigidly and frame a known-length reference in the same target plane.
2. Drag the ROI so its displayed width spans the reference edge to edge.
3. Open **Calibrate**, enter the physical length in millimeters, and save.
4. Do not change distance, zoom, orientation, capture format, or target plane. Recalibrate after any such change.

Calibration stores pixels per millimeter only on the device. Without a finite positive calibration, the UI and CSV expose displacement exclusively in pixels.

## Quality and warning behavior

The app surfaces invalid/out-of-band settings, timestamp discontinuities, dropped frames, excessive global motion, and low tracking confidence/texture. Output clamping occurs in the shader. Low-light and clipping detection are conservative quality signals and should be confirmed visually; any unstable, noisy, or implausible observation must be repeated with improved lighting and an independent sensor.

## Limitations

- CMOS rolling shutter can bend or phase-shift moving objects.
- Sensor noise, ISP processing, and image compression can be amplified as apparent motion.
- Mains-powered lighting can flicker inside the selected band and look like vibration.
- Perspective, parallax, autofocus, auto exposure, target rotation, and tripod/floor motion can create false translation.
- Vision reports image-plane translation. Deformation, rotation, and out-of-plane motion are not equivalent to rigid X/Y displacement.
- Frequency resolution depends on session duration, timestamps, frame rate, and dropped frames. Motion above the band or Nyquist limit cannot be recovered.
- A pixel/mm scale is valid only for its plane, focal configuration, orientation, resolution, and camera position.
- Results are not safety-certified and must not be used alone for shutdown, clearance, or personnel-safety decisions.

## Privacy

All processing and ProRes encoding are local. The app has no login, network service, advertising, analytics, tracking, telemetry, or upload code. It requests camera access and add-only Photos access. Files leave the app only after the user invokes iOS sharing.

## Developer setup

Requirements: stable Flutter, current Xcode compatible with App Store uploads, CocoaPods, iOS 15+, and an iPhone with a Metal-capable rear camera.

```sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build ios --debug --simulator
```

Run on a physical iPhone to validate camera formats, torch, Photos, actual FPS, and signal behavior. No credentials, signing assets, Pods, or build artifacts are committed.

## Validation status

Dart tests cover band validation/Nyquist limits, calibration math, calibrated and uncalibrated session CSV behavior, and the timestamp-aware reference band-pass with synthetic sines. Swift tests cover the filter coefficient, synthetic FFT frequency detection, and calibration conversion. GitHub Actions runs formatting, analysis, Dart tests, an unsigned simulator build, and native XCTest on macOS. This Linux development host does not provide Flutter/Xcode; see the latest CI run for Apple-toolchain proof.
The native GPU engine uses an independently implemented, multi-scale
gradient-domain Eulerian motion-magnification pipeline. It draws on published
motion-magnification research, but it is not RDI Technologies software and does
not claim to reproduce RDI's proprietary algorithms or calibrated hardware.
