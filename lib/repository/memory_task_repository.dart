import '../domain/task.dart';
import '../domain/trash.dart';
import 'task_repository.dart';

/// 内存实现：测试与控制台仿真用。不支持 watch（返回 null）。
class MemoryTaskRepository implements TaskRepository {
  final Map<String, Task> _store = {};
  final Map<String, TrashEntry> _trash = {};

  @override
  Future<List<Task>> loadAll() async {
    final tasks = _store.values.toList()
      ..sort((a, b) => a.created.compareTo(b.created));
    return tasks;
  }

  @override
  Future<Task?> getTask(String id) async => _store[id];

  @override
  Future<void> save(Task task) async => _store[task.id] = task;

  @override
  Future<void> delete(String id) async => _store.remove(id);

  @override
  Future<void> moveToTrash(String id) async {
    final t = _store.remove(id);
    if (t != null) _trash[id] = TrashEntry(task: t, deletedAt: DateTime.now());
  }

  @override
  Future<List<TrashEntry>> loadTrash() async => _trash.values.toList()
    ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));

  @override
  Future<void> restore(String id) async {
    final entry = _trash.remove(id);
    if (entry != null) _store[id] = entry.task;
  }

  @override
  Future<void> purgeFromTrash(String id) async => _trash.remove(id);

  @override
  Future<void> purgeTrash() async => _trash.clear();

  @override
  Future<int> pruneOrphans() async => 0; // 内存实现没有"副本文件"，无从整理

  @override
  Stream<RepositoryEvent>? watch() => null;

  @override
  List<String> get warnings => const [];

  void clear() {
    _store.clear();
    _trash.clear();
  }
}
