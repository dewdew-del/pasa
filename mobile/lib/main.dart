import 'package:flutter/material.dart';

import 'screens/connect_screen.dart';

void main() => runApp(const PasaApp());

ThemeData _theme(Brightness b) {
  final dark = b == Brightness.dark;
  final accent = dark ? const Color(0xFF5C9CFF) : const Color(0xFF1A5FD6);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF1A5FD6),
        brightness: b,
      ).copyWith(
        primary: accent,
        onPrimary: dark ? const Color(0xFF06142B) : Colors.white,
        surface: dark ? const Color(0xFF111111) : Colors.white,
        onSurface: dark ? Colors.white : const Color(0xFF111111),
        onSurfaceVariant: dark
            ? const Color(0xFFB4B4B4)
            : const Color(0xFF5F6368),
        outlineVariant: dark
            ? const Color(0xFF2A2A2A)
            : const Color(0xFFE6E8EA),
        error: dark ? const Color(0xFFE5566F) : const Color(0xFFC4242A),
      );
  const btnShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? Colors.black : const Color(0xFFF9FAFB),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? Colors.black : const Color(0xFFF9FAFB),
      scrolledUnderElevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: btnShape,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: btnShape,
        foregroundColor: scheme.onSurface,
        side: BorderSide(
          color: dark ? const Color(0xFF444444) : const Color(0xFFD1D5DB),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
  );
}

class PasaApp extends StatelessWidget {
  const PasaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pasa',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: const ConnectScreen(),
  );
}
