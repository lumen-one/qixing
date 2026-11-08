import 'dart:io';

import '../domain/logbook.dart';
import 'logbook_codec.dart';
import 'logbook_repository.dart';
import 'markdown_logbook_codec.dart';

/// Markdown 实现：任务目录下单个 `记录.md`（格式见 formats/logbook.md B.10）。
///
/// 没有 frontmatter、没有未知字段要保真，所以保存不必回读磁盘——直接按模型重写。
class MarkdownLogBookRepository implements LogBookRepository {
  final String dirPath;
  final LogBookCodec codec;
  final List<String> _warnings = [];
  final File _file;

  MarkdownLogBookRepository(this.dirPath, {LogBookCodec? codec})
      : codec = codec ?? MarkdownLogBookCodec(),
        _file = File('$dirPath${Platform.pathSeparator}记录.md');

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<LogBook> load() async {
    _warnings.clear();
    if (!_file.existsSync()) return LogBook();
    try {
      final raw = await _file.readAsString();
      final result = codec.decode(raw);
      _warnings.addAll(result.warnings);
      return result.book;
    } catch (e) {
      _warnings.add('记录.md: $e');
      return LogBook();
    }
  }

  @override
  Future<void> save(LogBook book) async {
    final raw = codec.encode(book);
    await _file.parent.create(recursive: true);
    await _file.writeAsString(raw);
  }
}
