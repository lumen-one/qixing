import '../domain/speednote.dart';
import 'speednote_repository.dart';

/// 内存实现（测试与仿真用；不落盘）。
class MemorySpeedNoteRepository implements SpeedNoteRepository {
  List<SpeedNote> _notes;
  final List<String> _warnings = [];

  MemorySpeedNoteRepository([List<SpeedNote> initial = const []])
      : _notes = List.unmodifiable(initial);

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<List<SpeedNote>> loadAll() async => _notes;

  @override
  Future<void> saveAll(List<SpeedNote> notes) async {
    _notes = List.unmodifiable(notes);
  }
}
