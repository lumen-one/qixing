import '../domain/logbook.dart';
import 'logbook_repository.dart';

/// 内存实现（测试与仿真用；不发时不落盘）。
class MemoryLogBookRepository implements LogBookRepository {
  LogBook _book;
  final List<String> _warnings = [];

  MemoryLogBookRepository([LogBook? initial])
      : _book = initial ?? LogBook();

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<LogBook> load() async => _book;

  @override
  Future<void> save(LogBook book) async {
    _book = book;
  }
}
