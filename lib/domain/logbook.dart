/// 记录册（ui-interaction.md §2 词汇表；存储格式见 formats/logbook.md B.10）。
///
/// **与主线不相交**：记录册不认主线——没有主线也照写，归档一条主线不改这里一行，
/// 也没有"只读"这回事。与任务的边界同样是硬的：记录不占工时、不进调度、不响提醒，
/// 也不进 `.gtd/log.md`（那是全 App 的操作流水）。
///
/// 一份册子 = 若干 [LogSegment]（日历上圈出来的连续日期段）+ 若干 [MonthNote]
/// （一个月一句）。纯 Dart，不认识 Flutter，也不认识任何服务。
library;

/// 同一天（只看年月日）。
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 取当天零点（记录与日期比较一律按"天"算）。
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// 一段记录 = 日历上圈出来的一段：**连续**日期 + 文字。段与段不重叠
/// （写入撞段即拒绝，见 `docs/sockets/logbook.md`）。
///
/// 起止只到"天"，且自动归一：结束早于开始时对调（手改文件写反了也不丢）。
class LogSegment {
  final DateTime start;
  final DateTime end;

  final String text;

  const LogSegment._({required this.start, required this.end, this.text = ''});

  factory LogSegment.range({
    required DateTime start,
    required DateTime end,
    String text = '',
  }) {
    final a = dayOf(start);
    final b = dayOf(end);
    return a.isAfter(b)
        ? LogSegment._(start: b, end: a, text: text)
        : LogSegment._(start: a, end: b, text: text);
  }

  /// 这一段覆盖 [day] 吗（含两端）。
  bool covers(DateTime day) {
    final d = dayOf(day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  /// 两段有没有共用一天（含两端，所以端点相接也算重叠）。
  bool overlaps(LogSegment other) =>
      !end.isBefore(other.start) && !other.end.isBefore(start);

  /// 覆盖的天数（至少 1）。
  int get dayCount => end.difference(start).inDays + 1;

  LogSegment copyWith({DateTime? start, DateTime? end, String? text}) =>
      LogSegment.range(
        start: start ?? this.start,
        end: end ?? this.end,
        text: text ?? this.text,
      );

  @override
  String toString() => 'LogSegment($start~$end, $text)';
}

/// 定位一段记录用的**身份**：起止日 + 当时的文字。
///
/// 命令通道不传下标。界面手里的下标是"按起始日排完序后的位置"，而服务每条命令
/// 都先重新读盘、再重新排序：中间若另一个引擎（悬浮面板）或人在 Obsidian 里加了一条
/// 更早的圈，同一个下标就指到别人身上，改错和删错都不会报错。三元组是内容的证据，
/// 落盘后按它找回原条目。
class LogSegmentRef {
  final DateTime start;
  final DateTime end;
  final String text;

  const LogSegmentRef({
    required this.start,
    required this.end,
    required this.text,
  });

  factory LogSegmentRef.of(LogSegment segment) => LogSegmentRef(
        start: segment.start,
        end: segment.end,
        text: segment.text,
      );

  /// 这段记录是不是它（起止按天比，文字逐字比）。
  bool matches(LogSegment segment) =>
      isSameDay(start, segment.start) &&
      isSameDay(end, segment.end) &&
      text == segment.text;

  @override
  String toString() => 'LogSegmentRef($start~$end, $text)';
}

/// 月记：一个月一条文字（记录页切到"月视图"时写的那些）。
///
/// 与 [LogSegment] 的分界线是**它不覆盖任何一天**：日历格子、记录列表都不认它，
/// 它只回答"这个月在干什么"。混进记录段里会让整月每一天都冒出同一句，所以是独立的
/// 类型（`docs/decisions/2026-10-25-mainline-month-note.md`）。
class MonthNote {
  final int year;

  /// 1–12。
  final int month;

  final String text;

  const MonthNote({
    required this.year,
    required this.month,
    required this.text,
  });

  bool isFor(int y, int m) => year == y && month == m;

  MonthNote copyWith({String? text}) =>
      MonthNote(year: year, month: month, text: text ?? this.text);

  @override
  String toString() => 'MonthNote($year-$month, $text)';
}

/// 整本记录册：全部记录段 + 全部月记，不可变快照。
class LogBook {
  final List<LogSegment> segments;
  final List<MonthNote> months;

  LogBook({
    List<LogSegment> segments = const [],
    List<MonthNote> months = const [],
  })  : segments = List.unmodifiable(segments),
        months = List.unmodifiable(months);

  /// 空册子（未装配记录服务的宿主与测试用它兜底）。
  static final LogBook empty = LogBook();

  /// 记录按起始日升序（日历与记录列表都按这个顺序读）。
  List<LogSegment> get segmentsInOrder =>
      [...segments]..sort((a, b) => a.start.compareTo(b.start));

  /// 那个月的月记；没写过 → null。
  MonthNote? monthNoteOf(int year, int month) {
    for (final n in months) {
      if (n.isFor(year, month)) return n;
    }
    return null;
  }

  /// 月记按年月升序。
  List<MonthNote> get monthsInOrder => [...months]..sort((a, b) {
        final byYear = a.year.compareTo(b.year);
        return byYear != 0 ? byYear : a.month.compareTo(b.month);
      });

  /// 有就改、没有就加；[text] 去掉首尾空白后为空 = 删掉这个月那条。
  ///
  /// 一个月只留一条，所以"再写一次"就是改，不叠第二条。
  List<MonthNote> withMonthNote(int year, int month, String text) {
    final t = text.trim();
    final next = [for (final n in months) if (!n.isFor(year, month)) n];
    if (t.isNotEmpty) {
      next.add(MonthNote(year: year, month: month, text: t));
    }
    return next;
  }

  LogBook copyWith({
    List<LogSegment>? segments,
    List<MonthNote>? months,
  }) =>
      LogBook(
        segments: segments ?? this.segments,
        months: months ?? this.months,
      );

  @override
  String toString() =>
      'LogBook(${segments.length} segments, ${months.length} month notes)';
}
