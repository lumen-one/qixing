import 'package:flutter/material.dart';
import 'package:qixing/ui/app_locale.dart';

/// 测试宿主的统一口径：中文资源 + 24 小时制。
///
/// 时间文案跟着系统的 `MediaQuery.alwaysUse24HourFormat` 走（ui-interaction.md §8）。
/// 测试环境默认是 12 小时制 + en_US，同一句断言会从 `18:00` 变成 `6:00 PM`。
/// 要测 12 小时制的写法，显式传 `use24: false`。
Widget testApp({
  required Widget home,
  bool use24 = true,
  ThemeData? theme,
}) =>
    MaterialApp(
      locale: appLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24),
        child: child ?? const SizedBox.shrink(),
      ),
      home: home,
    );
