import '../domain/speednote.dart';
import 'speednote_codec.dart';

/// `速记.md` 编解码（formatId: `md-speednote/1`，格式见 docs/formats/speednote.md）。
///
/// 文件结构：**一条速记一个 frontmatter 块**，块与块之间是这条速记的正文：
///
/// ```markdown
/// ---
/// id: sn-20261104-3f9c
/// title: 十一月
/// created: 2026-11-04T16:20
/// ---
///
/// ## 本周
///
/// - 侧边栏把手
/// ```
///
/// 保真：应用拥有的 frontmatter 字段**原地改写**，未知字段/注释/空行原样保留
/// （与 `主线.md` 同档）。**正文不保真**——它本身就是数据，保存时按模型重写。
/// 解析永不抛异常：坏块记告警后跳过。
///
/// 块的边界靠**下一段的 `id:`** 认（与主线同一套判据）：正文里单独一行 `---`
/// 照旧是水平分割线。
class MarkdownSpeedNoteCodec implements SpeedNoteCodec {
  /// 应用拥有的 frontmatter 字段。
  static const List<String> _ownedKeys = ['id', 'title', 'created'];

  @override
  String get formatId => 'md-speednote/1';

  @override
  bool canDecode(String raw) => raw.contains('---');

  @override
  SpeedNoteDecodeResult decode(String raw) {
    final notes = <SpeedNote>[];
    final warnings = <String>[];
    for (final block in _parse(raw)) {
      final id = block.fields['id']?.trim();
      if (id == null || id.isEmpty) {
        warnings.add('速记.md: 跳过缺少 id 的块');
        continue;
      }
      final created = _parseIso(block.fields['created'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      notes.add(SpeedNote(
        id: id,
        title: (block.fields['title'] ?? '').trim(),
        created: created,
        body: _trimBody(block.bodyLines),
      ));
    }
    return SpeedNoteDecodeResult(notes, warnings);
  }

  @override
  String encode(List<SpeedNote> notes, {String? originalRaw}) {
    final blocks = <String, _Block>{};
    if (originalRaw != null) {
      for (final b in _parse(originalRaw)) {
        final id = b.fields['id']?.trim();
        if (id != null && id.isNotEmpty) blocks[id] = b;
      }
    }
    final out = StringBuffer();
    for (var i = 0; i < notes.length; i++) {
      final n = notes[i];
      final b = blocks[n.id];
      final front = <String>[];
      final written = <String>{};
      if (b != null) {
        for (final line in b.frontLines) {
          final key = _keyOf(line);
          if (key != null && _ownedKeys.contains(key)) {
            front.add(_fieldLine(key, _value(n, key)));
            written.add(key);
          } else {
            front.add(line); // 未知字段 / 注释 / 空行：原样保留
          }
        }
      }
      for (final key in _ownedKeys) {
        if (written.contains(key)) continue;
        front.add(_fieldLine(key, _value(n, key)));
      }
      out.write('---\n${front.join('\n')}\n---\n\n');
      final body = n.body.trimRight();
      if (body.isNotEmpty) out.write('$body\n');
      if (i != notes.length - 1) out.write('\n');
    }
    final text = out.toString().trimRight();
    return text.isEmpty ? '' : '$text\n';
  }

  // ---------- 内部 ----------

  static String _fieldLine(String key, String? value) =>
      (value == null || value.isEmpty) ? '$key:' : '$key: $value';

  static String? _value(SpeedNote n, String key) {
    switch (key) {
      case 'id':
        return n.id;
      case 'title':
        return _oneLine(n.title);
      case 'created':
        return _fmtIso(n.created);
      default:
        return null;
    }
  }

  /// 正文去掉首尾空行（块之间的分隔空行不算正文）。
  static String _trimBody(List<String> lines) {
    var start = 0;
    var end = lines.length;
    while (start < end && lines[start].trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].trim().isEmpty) {
      end--;
    }
    if (start >= end) return '';
    return lines
        .sublist(start, end)
        .map((l) => l.replaceAll('\r', ''))
        .join('\n');
  }

  static List<_Block> _parse(String raw) {
    final lines = raw.split('\n');
    final blocks = <_Block>[];
    var i = 0;
    while (i < lines.length) {
      if (lines[i].trim() != '---') {
        i++;
        continue;
      }
      final fmStart = i + 1;
      var j = fmStart;
      while (j < lines.length && lines[j].trim() != '---') {
        j++;
      }
      if (j >= lines.length) break; // 未闭合：忽略尾部
      final frontLines = lines.sublist(fmStart, j);
      final fields = <String, String>{};
      for (final line in frontLines) {
        final idx = line.indexOf(':');
        if (idx <= 0) continue;
        var v = line.substring(idx + 1).trim();
        if (v.length >= 2 &&
            ((v.startsWith('"') && v.endsWith('"')) ||
                (v.startsWith("'") && v.endsWith("'")))) {
          v = v.substring(1, v.length - 1);
        }
        fields[line.substring(0, idx).trim()] = v;
      }
      final bodyLines = <String>[];
      var k = j + 1;
      while (k < lines.length) {
        if (lines[k].trim() == '---' && _startsNewBlock(lines, k + 1)) break;
        bodyLines.add(lines[k]);
        k++;
      }
      blocks.add(_Block(frontLines, fields, bodyLines));
      i = k;
    }
    return blocks;
  }

  /// 一行 `---` 是不是下一条速记的开头：后面那一小段里（到下一个 `---` 之前）
  /// 出现 `id:` 就算。
  static bool _startsNewBlock(List<String> lines, int from) {
    for (var i = from; i < lines.length && lines[i].trim() != '---'; i++) {
      if (lines[i].trimLeft().startsWith('id:')) return true;
    }
    return false;
  }

  static String? _keyOf(String line) {
    final idx = line.indexOf(':');
    if (idx <= 0) return null;
    return line.substring(0, idx).trim();
  }

  static String _oneLine(String s) =>
      s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtIso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}'
      'T${_two(d.hour)}:${_two(d.minute)}';

  static DateTime? _parseIso(String text) {
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})'
            r'(?:[T ](\d{1,2}):(\d{2}))?')
        .firstMatch(text.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final h = int.tryParse(m.group(4) ?? '0') ?? 0;
    final mi = int.tryParse(m.group(5) ?? '0') ?? 0;
    return DateTime(y, mo, d, h, mi);
  }
}

class _Block {
  final List<String> frontLines;
  final Map<String, String> fields;
  final List<String> bodyLines;

  const _Block(this.frontLines, this.fields, this.bodyLines);
}
