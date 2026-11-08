import '../domain/logbook.dart';
import 'logbook_codec.dart';

/// `记录.md` 编解码（formatId: `md-logbook/1`，格式见 formats/logbook.md B.10）。
///
/// 文件只有两段，没有 frontmatter——它没有 id、没有字段，正文就是全部数据：
///
/// ```markdown
/// ### 记录
///
/// - 2026-10-19 ~ 2026-10-21 连续三天都在写第三章
/// - 2026-10-20 单天一条就只写一个日期
///
/// ### 月记
///
/// - 2026-10 这个月把第三章写完
/// ```
///
/// 解析永不抛异常：认不出的行当人写的自由文字跳过。**正文不保真**——保存时按模型
/// 重写（局限登记在 B.10）。月记与记录段的分工见
/// `docs/decisions/2026-10-25-mainline-month-note.md`：月记不覆盖任何一天，所以它单独
/// 一段、单独一行格式。
class MarkdownLogBookCodec implements LogBookCodec {
  @override
  String get formatId => 'md-logbook/1';

  @override
  bool canDecode(String raw) => true;

  @override
  LogBookDecodeResult decode(String raw) {
    final segments = <LogSegment>[];
    final months = <MonthNote>[];
    final warnings = <String>[];
    _Section mode = _Section.other;
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#')) {
        mode = _sectionOf(t);
        continue;
      }
      if (!t.startsWith('- ')) continue;
      if (mode == _Section.segments) {
        final seg = _parseSegment(t);
        if (seg != null) segments.add(seg);
      } else if (mode == _Section.months) {
        final note = _parseMonthNote(t);
        if (note != null) {
          // 手写重复行时后者为准（一个月只留一条）
          months.removeWhere((n) => n.isFor(note.year, note.month));
          months.add(note);
        }
      }
    }
    if (segments.isEmpty && months.isEmpty && raw.trim().isNotEmpty) {
      // 有内容却一条都读不出来：多半是段标题被改坏了，提示一句，不猜。
      warnings.add('记录.md: 没读到任何记录段，检查 ### 记录 / ### 月记 两段标题');
    }
    return LogBookDecodeResult(
      LogBook(segments: segments, months: months),
      warnings,
    );
  }

  @override
  String encode(LogBook book) {
    final out = StringBuffer();
    out.write('### 记录\n\n');
    for (final s in book.segmentsInOrder) {
      out.write('${_encodeSegment(s)}\n');
    }
    // 一个月都没写就不留空段：文件里只有它真正装着的那些东西。
    if (book.months.isNotEmpty) {
      out.write('\n### 月记\n\n');
      for (final n in book.monthsInOrder) {
        out.write('${_encodeMonthNote(n)}\n');
      }
    }
    return out.toString();
  }

  // ---------- 行级编解码 ----------

  static String _encodeSegment(LogSegment s) {
    final head = isSameDay(s.start, s.end)
        ? _fmtDate(s.start)
        : '${_fmtDate(s.start)} ~ ${_fmtDate(s.end)}';
    final text = _oneLine(s.text).trim();
    return text.isEmpty ? '- $head' : '- $head $text';
  }

  static String _encodeMonthNote(MonthNote n) {
    final head = '${n.year.toString().padLeft(4, '0')}-${_two(n.month)}';
    final text = _oneLine(n.text).trim();
    return text.isEmpty ? '- $head' : '- $head $text';
  }

  /// 一行记录 → 圈。行首必须是日期，否则算人写的自由文字（忽略）。
  static LogSegment? _parseSegment(String line) {
    final m = RegExp(
      r'^-\s*(\d{4}-\d{2}-\d{2})(?:\s*~\s*(\d{4}-\d{2}-\d{2}))?\s*(.*)$',
    ).firstMatch(line);
    if (m == null) return null;
    final start = _parseDate(m.group(1)!);
    final end = _parseDate(m.group(2) ?? m.group(1)!);
    if (start == null || end == null) return null;
    return LogSegment.range(start: start, end: end, text: m.group(3)!.trim());
  }

  /// 一行月记 → 月记。行首必须是 `年-月`（两位数月份），否则忽略。
  ///
  /// 与 [_parseSegment] 的日期行不撞：那边要完整的 `年-月-日`，`2026-10` 匹配不上。
  static MonthNote? _parseMonthNote(String line) {
    final m = RegExp(r'^-\s*(\d{4})-(\d{1,2})\s*(.*)$').firstMatch(line);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    if (month < 1 || month > 12) return null;
    return MonthNote(year: year, month: month, text: m.group(3)!.trim());
  }

  // ---------- 结构解析 ----------

  /// 小标题 → 段落；认不出的返回 other（人加的别的小标题，整段不认）。
  static _Section _sectionOf(String trimmedLine) {
    final text = trimmedLine.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (text.startsWith('记录')) return _Section.segments;
    if (text.startsWith('月记')) return _Section.months;
    return _Section.other;
  }

  // ---------- 格式化 ----------

  static String _oneLine(String s) =>
      s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

  static DateTime? _parseDate(String text) {
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime(y, mo, d);
  }
}

enum _Section { segments, months, other }
