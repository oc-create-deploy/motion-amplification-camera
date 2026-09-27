import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('About & limitations')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: const [
            Text(
              'Motion Amplification Camera',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Text('Version 1.0.0', style: TextStyle(color: Colors.white60)),
            SizedBox(height: 24),
            _Section(
              'Privacy',
              'All camera processing, measurements, calibration, and snapshots remain on-device. There are no accounts, ads, analytics, trackers, or uploads. Exports happen only when you request them through the system share sheet.',
            ),
            _Section(
              'Algorithm',
              'Saved videos use Precision FFT only. The app records a high-fidelity source, applies a zero-phase temporal FFT band-pass across the complete recording, then adds only that filtered luminance variation back to the untouched source frames. It does not spatially warp or resample the source image. Saved playback can be accelerated from 1× to 8× without changing the FFT analysis timing, making very slow movement easier to compare. The live preview remains unamplified so it accurately represents framing and focus. Vision registration estimates ROI translation; a Hann-windowed vDSP FFT estimates dominant frequency.',
            ),
            _Section(
              'Limitations',
              'This is a visualization and diagnostic aid, not a certified safety instrument or calibrated sensor. Rolling shutter, compression and sensor noise, lighting flicker, perspective/parallax, tripod movement, low texture, dropped frames, and calibration geometry can distort results. Keep the target plane perpendicular to the camera and repeat observations with proper sensors.',
            ),
            _Section(
              'Recording',
              'Precision FFT needs enough time to observe repeated motion: record at least two cycles and preferably three. At 0.02 Hz one cycle is 50 seconds, so 100 seconds is the minimum and 150 seconds is recommended. Output is a high-fidelity Apple ProRes 4444 MOV. You can save it to Photos or share it with the CSV measurements; nothing is uploaded automatically.',
            ),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.body);
  final String title, body;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(height: 1.45)),
          ],
        ),
      );
}
