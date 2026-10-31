import 'package:flutter/material.dart';

class AppColors {
  static const deepPurple = Color(0xFF3B0764);
  static const purple = Color(0xFF6D28D9);
  static const violet = Color(0xFF7C3AED);
  static const header1 = Color(0xFF4C1D95);
  static const gold = Color(0xFFFACC15);
  static const lanternGold = Color(0xFFF59E0B);
  static const pink = Color(0xFFEC4899);
  static const background = Color(0xFFF8F9FA);
  static const facebook = Color(0xFF1877F2);
  static const textDark = Color(0xFF1F2937);
  static const inactive = Color(0xFF9CA3AF);
}

class AppTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.violet),
      );
}
