import 'package:flutter/widgets.dart';
import 'dart:ui';
import 'package:flutter/material.dart';

enum ConnectionMode { off, smart, global }

class AppColors {
  static const Color background = Color(0xFF101F2D);
  static const Color cardBackground = Color(0xFF1B2E40);
  
  // Connection Mode Colors
  static const Color modeOff = Color(0xFF2C3E50);
  static const Color modeSmart = Color(0xFF7FE3B1);
  static const Color modeGlobal = Color(0xFFFF9F1C);
  
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Colors.grey;
}

class AppStrings {
  static const String modeOff = '关闭';
  static const String modeSmart = '智能';
  static const String modeGlobal = '全局';
  
  static const String trafficLabel = '流量包可用: 0.00GB';
  static const String expiryLabel = '获取中...';
  static const String countryName = 'Japan';
  static const String connectionStatus = 'automatic connection';
}

class AppAssets {
  // Helper to dynamically resolve Android-style DPI folders based on device pixel ratio
  static String resolveImage(BuildContext context, String fileName) {
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    String folder;
    if (dpr >= 4.0) {
      folder = 'xxxhdpi';
    } else if (dpr >= 3.0) {
      folder = 'xxxhdpi'; // Using xxxhdpi for 3.0+ as well if xxhdpi is strictly 2.0-3.0
    } else if (dpr >= 2.0) {
      folder = 'xxhdpi';
    } else if (dpr >= 1.5) {
      folder = 'xhdpi';
    } else {
      folder = 'mdpi';
    }
    return 'assets/images/$folder/$fileName';
  }

  // To use this, you must call AppAssets.resolveImage(context, 'logo.png') in your build methods.
  // For places where context is not available or you want a static fallback, we define static getters.
  // Note: static const cannot use context, so they will point to a default (e.g. xxxhdpi) if used directly without context.
  
  static const String icSettings = 'assets/images/settings.svg';
  static const String icUser = 'assets/images/user.svg';
  static const String icCountry = 'assets/country/japan.svg';
  static const String icChevronRight = 'assets/images/chevron-right.svg';
  static const String icClose = 'assets/images/close.svg';
}
