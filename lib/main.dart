import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  final prefs = await SharedPreferences.getInstance();
  runApp(
    MotionApp(showOnboarding: !(prefs.getBool('onboarding_complete') ?? false)),
  );
}

class MotionApp extends StatelessWidget {
  const MotionApp({super.key, required this.showOnboarding});
  final bool showOnboarding;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Motion Amplification Camera',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff21c8f6),
            brightness: Brightness.dark,
            surface: const Color(0xff09131d),
            error: const Color(0xffffb14a),
          ),
          scaffoldBackgroundColor: const Color(0xff050b11),
          cardTheme: const CardThemeData(color: Color(0xff0d1b27)),
          sliderTheme: const SliderThemeData(
            showValueIndicator: ShowValueIndicator.onDrag,
          ),
        ),
        home: showOnboarding ? const OnboardingScreen() : const HomeScreen(),
      );
}
