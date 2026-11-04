import 'dart:io';

import '../domain/speednote.dart';
import 'markdown_speednote_codec.dart';
import 'speednote_codec.dart';
import 'speednote_repository.dart';

/// Markdown 实现：任务目录下单个 `速记.md`（附录 B.9）。
///
/// 保存前重读磁盘内容做"未知字段保真"的基准（与 `主线.md` 同一套策略）。
class MarkdownSpeedNoteRepository implements SpeedNoteRepository {
  final String dirPath;
  final SpeedNoteCodec codec;
  final List<String> _warnings = [];
  final File _file;

  MarkdownSpeedNoteRepository(this.dirPath, {SpeedNoteCodec? codec})
      : codec = codec ?? MarkdownSpeedNoteCodec(),
        _file = File('$dirPath${Platform.pathSeparator}速记.md');

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<SpeedNote>> loadAll() async {
    _warnings.clear();
    if (!_file.existsSync()) return const [];
    try {
      final raw = await _file.readAsString();
      final result = codec.decode(raw);
      _warnings.addAll(result.warnings);
      return result.notes;
    } catch (e) {
      _warnings.add('速记.md: $e');
      return const [];
    }
  }

  @override
  Future<void> saveAll(List<SpeedNote> notes) async {
    final original = _file.existsSync() ? await _file.readAsString() : null;
    final raw = codec.encode(notes, originalRaw: original);
    await _file.parent.create(recursive: true);
    await _file.writeAsString(raw);
  }
}
