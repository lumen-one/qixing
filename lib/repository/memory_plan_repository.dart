import '../domain/plan.dart';
import 'plan_repository.dart';

/// 内存实现（测试与仿真用；不落盘）。
class MemoryPlanRepository implements PlanRepository {
  PlanDocument _doc;
  final List<String> _warnings = [];

  MemoryPlanRepository([
    List<DayPlan> initial = const [],
    List<PlanEntry> template = const [],
  ]) : _doc = PlanDocument(days: initial, template: template);

  @override
  List<String> get warnings => List.unmodifiable(_warnings);

  @override
  Future<PlanDocument> load() async => _doc;

  @override
  Future<void> save(PlanDocument doc) async {
    _doc = doc;
  }
}
