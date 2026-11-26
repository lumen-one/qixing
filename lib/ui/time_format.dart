import 'package:flutter/material.dart';

/// 时间显示的唯一出口（§8「时间的写法全应用只有一种」）。
///
/// 判据只有系统的 [MediaQueryData.alwaysUse24HourFormat]：开 24 就写 `18:00`，
/// 开 12 就写 `下午6:00`。应用内不另设开关。**不要在各处手拼 `HH:mm`**——两套
/// 写法并存，就会出现"选择器是 12、列表是 24"。
///
/// **存盘与通知文案不走这里**：`tasks.md`、`.gtd/` 里的时刻与通知标题固定 24
/// 小时制，跨午夜的时间段只有这种写法不产生歧义。
String fmtClock(BuildContext context, DateTime d) =>
    fmtClockOf(context, TimeOfDay.fromDateTime(d));

String fmtClockOf(BuildContext context, TimeOfDay t) {
  final l10n = MaterialLocalizations.of(context);
  final raw = l10n.formatTimeOfDay(
    t,
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  // 中文 CLDR 在「上午/下午」与数字之间留一个空格，那是给拉丁 AM/PM 的位置；
  // 中文不留——240dp 的行上这 4dp 是标题的。
  for (final p in const <String>['上午 ', '下午 ']) {
    if (raw.startsWith(p)) {
      return '${p.trimRight()}${raw.substring(p.length)}';
    }
  }
  return raw;
}

/// 「一天里的第几分钟」→ 同一套写法（设置页的工作时间窗、通知时间段）。
String fmtClockMinutes(BuildContext context, int minuteOfDay) => fmtClockOf(
      context,
      TimeOfDay(hour: minuteOfDay ~/ 60, minute: minuteOfDay % 60),
    );

/// 带日期的时刻（提醒横幅、详情卡）。日期部分不随语言变。
String fmtDateTime(BuildContext context, DateTime d) =>
    '${d.month}-${_two(d.day)} ${fmtClock(context, d)}';

/// 固定 24 小时制的时刻写法，**只给刻度用**：编排页的时间轴与添加行。
///
/// 那一列是纵向标尺，不是读数——240dp 的面板里「下午6:00」比 `18:00` 多占两个
/// 字宽，会把添加行的输入框挤到 100dp 以下。行尾签、详情卡、设置页这些**读数**
/// 仍走 [fmtClock]。
String clock24(int minuteOfDay) =>
    '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:'
    '${(minuteOfDay % 60).toString().padLeft(2, '0')}';

String _two(int n) => n.toString().padLeft(2, '0');
