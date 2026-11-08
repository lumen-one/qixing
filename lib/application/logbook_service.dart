import '../domain/logbook.dart';
import '../repository/logbook_repository.dart';

/// 记录册的应用服务（panels/record.md）。
///
/// **与 MainlineService 完全独立**：这里没有一条命令需要主线 id，也没有"只读"这回事
/// ——没有主线照样加段，主线归档不改这里一行。它只做三件事：读整份 `记录.md`、
/// 改一处、整份写回。
///
/// 每个命令都是"**先读盘 → 改一处 → 整份写回**"：两个引擎（应用内 / 悬浮窗）可能同时
/// 写同一个文件，读一遍再改能把"别人刚加的那一段"带上，不至于被本地旧内存态抹掉。
class LogBookService {
  final LogBookRepository repo;

  LogBook _book = LogBook.empty;

  LogBookService({required this.repo});

  /// 解析告警（诊断用）。
  List<String> get warnings => repo.warnings;

  /// 当前这一份（不可变快照）。
  LogBook get book => _book;

  /// 读盘（启动 / 文件变更 / 回前台时调；幂等）。
  Future<void> load() async {
    _book = await repo.load();
  }

  /// 加一段记录（日历上拖选一段 → 写文字）。与已有段共用一天就拒绝。
  Future<void> add({
    required DateTime start,
    required DateTime end,
    String text = '',
  }) async {
    final disk = await repo.load();
    final segment = LogSegment.range(start: start, end: end, text: text);
    _requireNoOverlap(disk.segments, segment);
    await _write(disk.copyWith(segments: [...disk.segments, segment]));
  }

  /// 改一段记录（文字 / 起止日期）。
  ///
  /// 按 [ref] 找回原条目，**不按下标**：界面算出的下标是"排完序后的位置"，而这里
  /// 每次都要重新读盘再排序，中间别人加了一条更早的记录就会改到别人身上
  /// （见 [LogSegmentRef]）。找不到 = 这条已经不在了，抛错让界面提示，不猜。
  Future<void> update(
    LogSegmentRef ref, {
    DateTime? start,
    DateTime? end,
    String? text,
  }) async {
    final disk = await repo.load();
    final segments = [...disk.segmentsInOrder];
    final i = segments.indexWhere(ref.matches);
    if (i < 0) throw StateError('这段记录已经不在了');
    final updated = segments[i].copyWith(start: start, end: end, text: text);
    final others = [...segments]..removeAt(i);
    _requireNoOverlap(others, updated);
    segments[i] = updated;
    await _write(disk.copyWith(segments: segments));
  }

  /// 删一段记录：同样按 [ref] 定位；已经不在 = 目的已达成，什么都不做。
  Future<void> remove(LogSegmentRef ref) async {
    final disk = await repo.load();
    final segments = [...disk.segmentsInOrder];
    final i = segments.indexWhere(ref.matches);
    if (i < 0) return;
    segments.removeAt(i);
    await _write(disk.copyWith(segments: segments));
  }

  /// 写 / 改某个月的月记。一个月只留一条，所以再写就是改；[text] 为空 = 删掉这条。
  Future<void> setMonthNote(int year, int month, String text) async {
    final disk = await repo.load();
    await _write(disk.copyWith(months: disk.withMonthNote(year, month, text)));
  }

  // ---------- 内部 ----------

  /// 段与段不重叠：只要共用一天就拒绝，报出撞到的那一段。抛错发生在落盘之前，
  /// 盘上不会多出半条记录。不自动裁剪——那会悄悄改掉用户亲手拖出来的范围。
  static void _requireNoOverlap(
    List<LogSegment> existing,
    LogSegment candidate,
  ) {
    for (final s in existing) {
      if (!s.overlaps(candidate)) continue;
      final label = s.text.trim().isEmpty ? '（没写文字）' : s.text.trim();
      throw StateError(
        '这段日期和「$label」重叠了：'
        '${s.start.month} 月 ${s.start.day} 日 – '
        '${s.end.month} 月 ${s.end.day} 日',
      );
    }
  }

  Future<void> _write(LogBook next) async {
    await repo.save(next);
    _book = next;
  }
}
