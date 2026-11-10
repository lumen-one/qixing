import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/application/today_view.dart';
import 'package:qixing/domain/routine.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/markdown_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/pool_panel.dart';
import 'package:qixing/ui/widgets/task_selection.dart';

/// 任务池下拉搜索（`panels/pool.md`『下拉搜索』）：页顶拉出一条搜索框，
/// 标题 / 备注 / 标签取并集、空格分词按 AND，两段结构保留。
void main() {
  Task task(
    String id,
    String title, {
    String desc = '',
    List<String> tags = const [],
  }) =>
      Task(id: id, title: title, description: desc, tags: tags);

  group('filterPoolView', () {
    final report = task('a', '交周报', desc: '找那家店的发票', tags: ['工作']);
    final note = task('b', '写笔记');
    final view = PoolView(
      plan: [report],
      loose: [note],
      rows: [PoolTaskRow(report)],
    );

    test('空查询原样返回（同一个对象，不重建）', () {
      expect(identical(filterPoolView(view, ''), view), isTrue);
      expect(identical(filterPoolView(view, '   '), view), isTrue);
    });

    test('标题、备注、标签三者取并集', () {
      expect(filterPoolView(view, '周报').rows, hasLength(1));
      expect(filterPoolView(view, '发票').rows, hasLength(1),
          reason: '备注里的词也要能搜到');
      expect(filterPoolView(view, '工作').rows, hasLength(1),
          reason: '标签参与匹配');
    });

    test('空格分词按 AND', () {
      expect(filterPoolView(view, '周报 发票').rows, hasLength(1));
      expect(filterPoolView(view, '周报 笔记').rows, isEmpty);
    });

    test('两段各自过滤，不串到另一段', () {
      final onlyNote = filterPoolView(view, '笔记');
      expect(onlyNote.loose, hasLength(1));
      expect(onlyNote.rows, isEmpty);
      expect(onlyNote.plan, isEmpty, reason: 'isEmpty 要跟着过滤结果走');
    });

    test('周期条目按标题匹配', () {
      final routine = Routine(
        id: 'r1',
        title: '每周复盘',
        created: DateTime(2026, 1, 1),
      );
      final withRoutine = PoolView(
        plan: const [],
        loose: const [],
        rows: [PoolRoutineRow(routine, DateTime(2026, 11, 14))],
      );
      expect(filterPoolView(withRoutine, '复盘').rows, hasLength(1));
      expect(filterPoolView(withRoutine, '交周报').rows, isEmpty);
    });

    test('大小写不敏感', () {
      final en = task('c', 'Write Weekly Report');
      final v = PoolView(plan: [en], loose: const [], rows: [PoolTaskRow(en)]);
      expect(filterPoolView(v, 'weekly').rows, hasLength(1));
    });
  });

  testWidgets('下拉拉出搜索框，输入即过滤；点 × 清空并收起', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('gtd_pool_search');
    addTearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final svc = TaskService(
      repo: MarkdownTaskRepository(tmp.path),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      scheduleMode: ScheduleMode.standard,
    );
    await tester.runAsync(() async {
      await svc.createTask(
        title: '交周报',
        description: '找那家店的发票',
        deadline: DateTime.now().add(const Duration(days: 3)),
      );
      await svc.createTask(title: '写笔记');
      await svc.createTask(title: '收拾房间');
    });
    final controller = AppController(service: svc, taskDir: tmp.path);
    await controller.updateSettings(
      controller.settings.copyWith(scheduleMode: ScheduleMode.standard),
    );
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PoolPanel(controller: controller, selection: selection),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: '还没拉出来');
    expect(find.text('写笔记'), findsOneWidget);

    // 从列表顶部的条目往下拖 = 滚到顶继续下拉（标准档：三件都在池子里）。
    await tester.drag(find.text('交周报'), const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '过阈值就展开并聚焦');
    expect(find.text('搜索任务池'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: '拉出来就能直接打字',
    );

    await tester.enterText(find.byType(TextField), '发票');
    await tester.pumpAndSettle();
    expect(find.text('交周报'), findsOneWidget, reason: '备注命中');
    expect(find.text('写笔记'), findsNothing);
    expect(find.text('收拾房间'), findsNothing);

    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的条目'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: '× 收起');
    expect(find.text('写笔记'), findsOneWidget, reason: '清空后列表复原');
    expect(find.text('收拾房间'), findsOneWidget);
  });

  testWidgets('搜索态散件段不摆拖把手，收起后回来', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('gtd_pool_search_grip');
    addTearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final svc = TaskService(
      repo: MarkdownTaskRepository(tmp.path),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      scheduleMode: ScheduleMode.standard,
    );
    await tester.runAsync(() async {
      await svc.createTask(title: '写笔记');
      await svc.createTask(title: '收拾房间');
    });
    final controller = AppController(service: svc, taskDir: tmp.path);
    await controller.updateSettings(
      controller.settings.copyWith(scheduleMode: ScheduleMode.standard),
    );
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PoolPanel(controller: controller, selection: selection),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2),
        reason: '平时散件段可拖');

    controller.openPoolSearch();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '笔记');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNothing,
        reason: '过滤后的子集写 pool_order 会打乱没显示的件');

    controller.closePoolSearch();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
  });
}
