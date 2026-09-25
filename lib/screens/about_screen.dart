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
              'The native engine processes luminance through a spatial reduction stage. Two timestamp-aware first-order low-pass states form the temporal band-pass: LP(upper cutoff) − LP(lower cutoff). The amplified band is reconstructed and clamped on the GPU. Vision registration estimates ROI translation; a Hann-windowed vDSP FFT estimates dominant frequency.',
            ),
            _Section(
              'Limitations',
              'This is a visualization and diagnostic aid, not a certified safety instrument or calibrated sensor. Rolling shutter, compression and sensor noise, lighting flicker, perspective/parallax, tripod movement, low texture, dropped frames, and calibration geometry can distort results. Keep the target plane perpendicular to the camera and repeat observations with proper sensors.',
            ),
            _Section(
              'Recording',
              'Every analysis session records the actual amplified output locally as a high-fidelity Apple ProRes 4444 MOV, without bitrate or inter-frame compression settings. You can save that video to Photos or share it with the CSV measurements; nothing is uploaded automatically.',
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
