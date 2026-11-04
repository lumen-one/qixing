import '../domain/plan.dart';
import 'plan_codec.dart';

/// `编排.md` 编解码（formatId: `md-plan/1`，格式见 docs/formats/plan.md）。
///
/// 文件结构：**一天一段**，段标题是 `### yyyy-MM-dd`（`##` 也认），段内一行一条：
///
/// ```markdown
/// ### 循环
///
/// - 08:30 晨会
/// - 12:30 午餐休息
///
/// ### 2026-11-04 ·循环
///
/// - 08:30 晨会
/// - 12:30 午餐休息
///
/// ### 2026-10-22
///
/// - 09:30 项目评审
/// ```
///
/// `### 循环` 是每日循环的模板段（至多一段，写在最前）；日期段头带 `·循环` 表示那天是
/// 循环生成的——那种段空了也照写，挡住下一次生成。
///
/// 行序就是顺序，编码时**不按时刻重排**。**正文不保真**：不属于日期段或条目行的
/// 自由文字保存时消失（局限登记在 B.7）。解析永不抛异常：认不出的行直接跳过。
class MarkdownPlanCodec implements PlanCodec {
  @override
  String get formatId => 'md-plan/1';

  /// 模板段的标题（`#` 后面只有这两个字）。
  static const String templateHeading = '循环';

  /// 日期段头后面的循环记号。
  static const String repeatMark = '循环';

  /// 条目行：`- ` / `* ` 开头。`- [ ]` 这种复选框行不认——那不是编排。
  static final RegExp _bullet = RegExp(r'^[-*]\s+(.*)$');

  /// 时刻锚点：行首的 `H:mm` / `HH:mm`，后面必须还有标题。
  static final RegExp _time = RegExp(r'^(\d{1,2}):(\d{2})\s+(\S.*)$');

  /// 日期段头：`2026-11-04` 或 `2026-11-04 ·循环`。
  static final RegExp _dayHeading =
      RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:\s*·\s*循环)?$');

  /// 模板段在解析内部用的键；真实日期键是 `yyyy-MM-dd`，撞不上。
  static const String _templateKey = templateHeading;

  @override
  PlanDecodeResult decode(String raw) {
    final entries = <String, List<PlanEntry>>{};
    final dayOf = <String, DateTime>{};
    final repeated = <String, bool>{};
    final warnings = <String>[];
    String? currentKey;

    for (final line in raw.split('\n')) {
      final text = line.replaceAll('\r', '').trim();
      if (text.isEmpty) continue;

      if (text.startsWith('#')) {
        final heading = text.replaceFirst(RegExp(r'^#+\s*'), '').trim();
        if (heading == templateHeading) {
          currentKey = _templateKey;
          entries.putIfAbsent(_templateKey, () => []);
          continue;
        }
        final parsed = _parseDayHeading(heading);
        currentKey = parsed == null ? null : planDayKey(parsed.day);
        if (parsed != null && currentKey != null) {
          entries.putIfAbsent(currentKey, () => []);
          dayOf[currentKey] = parsed.day;
          repeated[currentKey] = parsed.repeated;
        }
        continue;
      }

      // 段外的自由文字：忽略（保存时消失，B.7 已登记）。
      final key = currentKey;
      if (key == null) continue;

      final bullet = _bullet.firstMatch(text);
      if (bullet == null) continue;
      final entry = _parseEntry(bullet.group(1)!.trim());
      if (entry == null) {
        warnings.add('编排.md: 跳过空条目');
        continue;
      }
      entries[key]!.add(entry);
    }

    final template = entries.remove(_templateKey) ?? const <PlanEntry>[];
    final days = [
      for (final e in entries.entries)
        DayPlan(
          day: dayOf[e.key]!,
          entries: e.value,
          repeated: repeated[e.key] ?? false,
        ),
    ]..sort((a, b) => b.day.compareTo(a.day));
    return PlanDecodeResult(days, warnings, template: template);
  }

  @override
  String encode(List<DayPlan> days, {List<PlanEntry> template = const []}) {
    final sorted = [...days]..sort((a, b) => b.day.compareTo(a.day));
    final out = StringBuffer();
    if (template.isNotEmpty) {
      out.write('### $templateHeading\n\n');
      for (final e in template) {
        out.write(_entryLine(e));
      }
      out.write('\n');
    }
    for (final d in sorted) {
      // 空的一天不落行，文件不留空段；**循环生成的日子例外**——那个空段正是
      // "这天已经排过了、别再补回来"的唯一凭据。
      if (d.entries.isEmpty && !d.repeated) continue;
      final mark = d.repeated ? ' ·$repeatMark' : '';
      out.write('### ${planDayKey(d.day)}$mark\n\n');
      for (final e in d.entries) {
        out.write(_entryLine(e));
      }
      out.write('\n');
    }
    final text = out.toString().trimRight();
    return text.isEmpty ? '' : '$text\n';
  }

  // ---------- 内部 ----------

  static String _entryLine(PlanEntry e) {
    final time = e.timeText;
    final title = _oneLine(e.title);
    return time == null ? '- $title\n' : '- $time $title\n';
  }

  /// `2026-11-04` / `2026-11-04 ·循环` → 当天零点 + 是否循环生成；不是日期就返回 null。
  static ({DateTime day, bool repeated})? _parseDayHeading(String text) {
    final m = _dayHeading.firstMatch(text);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return (
      day: DateTime(year, month, day),
      repeated: text.contains(repeatMark),
    );
  }

  /// 一行条目 → 一条编排。时刻越界（`25:00`）按"没有时刻"处理，原文留在标题里。
  static PlanEntry? _parseEntry(String body) {
    if (body.isEmpty) return null;
    final m = _time.firstMatch(body);
    if (m != null) {
      final hour = int.parse(m.group(1)!);
      final minute = int.parse(m.group(2)!);
      if (hour <= 23 && minute <= 59) {
        return PlanEntry(
          minutesOfDay: hour * 60 + minute,
          title: m.group(3)!.trim(),
        );
      }
    }
    return PlanEntry(title: body);
  }

  static String _oneLine(String s) =>
      s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
}
