import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// 应用的语言与地区，两个 `MaterialApp`（主引擎 + 悬浮面板）共用。
///
/// 界面文案全是手写中文，这一层管的是**内置组件**的语言：日期 / 时间选择器的月份名、
/// 按钮，以及 12 小时制下上午下午怎么写。不挂它，那些组件跑在 en_US 上——系统开 12
/// 小时制时弹出的是「6:00 PM」，列表上却写着「18:00」。
const Locale appLocale = Locale('zh', 'CN');

const List<Locale> appSupportedLocales = <Locale>[
  Locale('zh', 'CN'),
  Locale('en'),
];

const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];
