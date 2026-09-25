import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;
  static const pages = [
    (
      'See motion you cannot easily see',
      'Mount the iPhone on a rigid tripod. Keep the structure framed, stationary, and well lit. The phone must not be hand-held.',
      Icons.videocam_outlined,
    ),
    (
      'Give tracking a clear target',
      'Choose a textured, high-contrast area. Flat, reflective, dark, or changing surfaces reduce registration quality.',
      Icons.center_focus_strong,
    ),
    (
      'Choose a valid frequency band',
      'Measured frame rate limits the usable band. The app keeps the upper cutoff below 45% of measured FPS and reports dropped frames.',
      Icons.graphic_eq,
    ),
    (
      'Interpret with care',
      'Rolling shutter, flickering lights, perspective, noise, and camera movement can create false motion. Calibration is specific to one plane and setup.',
      Icons.warning_amber_rounded,
    ),
    (
      'Inspection aid — not a safety instrument',
      'This visualization is not certified, metrology-grade, or a substitute for calibrated sensors, engineering review, or safe work procedures. Processing stays on this iPhone.',
      Icons.health_and_safety_outlined,
    ),
  ];
  Future<void> _finish() async {
    await (await SharedPreferences.getInstance()).setBool(
      'onboarding_complete',
      true,
    );
    if (mounted) {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Before you measure')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (v) => setState(() => _page = v),
                  children: [
                    for (final p in pages)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              p.$3,
                              size: 88,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 32),
                            Text(
                              p.$1,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 20),
                            Text(
                              p.$2,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(height: 1.5),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Semantics(
                label: 'Onboarding page ${_page + 1} of ${pages.length}',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    pages.length,
                    (i) => Container(
                      margin: const EdgeInsets.all(4),
                      width: i == _page ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white30,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: FilledButton.icon(
                  onPressed: _page == pages.length - 1
                      ? _finish
                      : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                  icon: Icon(
                    _page == pages.length - 1
                        ? Icons.check
                        : Icons.arrow_forward,
                  ),
                  label: Text(
                    _page == pages.length - 1
                        ? 'I understand — continue'
                        : 'Next',
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
