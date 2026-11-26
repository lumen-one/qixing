import '../domain/schedule.dart';
import '../domain/task.dart';
import 'today_view.dart';

/// **每日收尾提醒**（ui-interaction.md §7.2 / 决定卡 2026-11-26）：
/// 当天固定时刻把"今日清单还剩几件"报一次。
///
/// 它走站点表，是 `ReminderDispatcher` 的第四个
/// 提醒源——与编排条目一样，站点 id 不对应任何任务，查不到是正常的。仿编排的 `plan|`：
/// 这个串只在挂闹钟那一趟里认人，不落盘、不进任务文件。
const String dailyDigestPrefix = 'daily|';

String dailyDigestId(DateTime day) => '$dailyDigestPrefix${dayMark(day)}';

bool isDailyDigestId(String id) => id.startsWith(dailyDigestPrefix);

/// 一次收尾提醒的定稿：站点 id、到点时刻、件数与文案。
class DailyDigest {
  final String id;

  /// 下一次设定时刻（今天还没到就是今天，过了就明天）。
  final DateTime at;

  /// 这一站报的件数（今日页的编号条目）。
  final int count;

  final String title;

  /// 前几个标题；没有标题（理论不可达，件数 > 0 就有）时为 null。
  final String? body;

  const DailyDigest({
    required this.id,
    required this.at,
    required this.count,
    required this.title,
    this.body,
  });
}

/// 下一次收尾时刻：严格晚于 [now] 的那一次。**过点不补**——设定时刻已过就顺延到明天，
/// 不套时点提醒那 30 分钟的补响宽限（那时用户多半正看着清单，这条提醒没有新信息）。
DateTime nextDailyDigestAt(DateTime now, int minutesOfDay) {
  final hour = minutesOfDay ~/ 60;
  final minute = minutesOfDay % 60;
  final today = DateTime(now.year, now.month, now.day, hour, minute);
  if (today.isAfter(now)) return today;
  return DateTime(now.year, now.month, now.day + 1, hour, minute);
}

/// 组一份收尾提醒；今日页一件编号条目都不剩时返回 null——**没未完成的任务就不挂站**。
///
/// 口径 = [buildTodayView] 的编号条目（逾期 + 开始型 + 截止型 + 插队件）。挂起是长期
/// 意图（没有截止），页底散件没有日期，例行实例默认不响——三者都不算，否则这条提醒会
/// 天天为它们响，最后被人关掉。
///
/// 视图按**将要响的那一刻**（`at`）算，不是按 `now`：明天那一站报的是明天的清单
/// （今天的未完件到期后自然进逾期组），而不是把今天的数字冻在那儿。桌面"到点现算"
/// 那条路没有站点时刻，传 [viewAt] = 此刻。
DailyDigest? buildDailyDigest({
  required List<Task> tasks,
  required ScheduleResult? schedule,
  required DateTime now,
  required int minutesOfDay,
  ScheduleMode scheduleMode = ScheduleMode.standard,
  int maxTitles = 3,
  DateTime? viewAt,
}) {
  final at = nextDailyDigestAt(now, minutesOfDay);
  final view = buildTodayView(
    tasks: tasks,
    schedule: schedule,
    // 默认按**将要响的那一刻**看清单；桌面那条"到点现算"的路径没有站点时刻，
    // 传 viewAt = 现在，报的就是此刻这一份。
    now: viewAt ?? at,
    scheduleMode: scheduleMode,
  );
  final pending = <Task>[...view.numbered];
  // 件数是给人看的第一眼信息，列出来的前三个按"最急的在前"排：截止越早越靠前，
  // 没有截止的（只会是插队件一类）垫底。
  pending.sort(_byDeadline);
  if (pending.isEmpty) return null;
  final names = pending.take(maxTitles).map((t) => t.title).join('、');
  return DailyDigest(
    id: dailyDigestId(at),
    at: at,
    count: pending.length,
    title: '今天还剩 ${pending.length} 件',
    body: pending.length > maxTitles ? '$names…' : names,
  );
}

int _byDeadline(Task a, Task b) {
  final da = a.deadline;
  final db = b.deadline;
  if (da != null && db != null) return da.compareTo(db);
  if (da != null) return -1;
  if (db != null) return 1;
  return a.title.compareTo(b.title);
}
