import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/completed_panel.dart';
import 'package:qixing/ui/panels/trash_panel.dart';
import 'package:qixing/ui/widgets/task_selection.dart';

/// 回收站覆盖页（panels/trash.md §6.14）：
/// 入口是已完成页的下拉，页里只有"恢复"与"清空"两件事。
void main() {
  Future<AppController> build() async {
    final tmp = Directory.systemTemp.createTempSync('gtd_trash');
    addTearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
    );
    await svc.createTask(title: '甲');
    await svc.createTask(title: '乙');
    return AppController(service: svc, taskDir: tmp.path);
  }

  testWidgets('已完成页滚到顶再下拉 = 打开回收站', (tester) async {
    final controller = await build();
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompletedPanel(controller: controller, selection: selection),
      ),
    ));
    await tester.pumpAndSettle();
    expect(controller.trashOpen, isFalse);

    // 空态也要能拉：已完成页空着时，正是要去回收站捞东西的时候。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(controller.trashOpen, isTrue);
  });

  testWidgets('回收站页：列出条目，行尾恢复即回清单', (tester) async {
    final controller = await build();
    final ids = [for (final t in controller.tasks) t.id];
    await controller.deleteTask(ids.first);
    controller.openTrash();
    await controller.refreshTrash();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TrashOverlay(controller: controller, onClose: controller.closeTrash),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsNothing, reason: '只有删掉的才在回收站里');

    await tester.tap(find.byIcon(Icons.restore));
    await tester.pumpAndSettle();
    expect(controller.tasks.any((t) => t.id == ids.first), isTrue);
    expect(find.text('甲'), findsNothing);
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('清空回收站：二次确认后清单空，按钮变灰', (tester) async {
    final controller = await build();
    final ids = [for (final t in controller.tasks) t.id];
    await controller.deleteTask(ids.first);
    await controller.deleteTask(ids.last);
    controller.openTrash();
    await controller.refreshTrash();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TrashOverlay(controller: controller, onClose: controller.closeTrash),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('2 件'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    expect(find.text('清空回收站？'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(controller.trashEntries, isEmpty);
    expect(find.text('回收站是空的'), findsOneWidget);
    expect(controller.tasks, isEmpty, reason: '真删，不会回到清单');
  });

  testWidgets('窄面板（240dp）不溢出：长标题 + 行尾日期与恢复钮', (tester) async {
    final controller = await build();
    final long = await controller.createTask(title: '把这份很长的季度复盘文档整理成可以发出去的版本');
    await controller.deleteTask(long.id);
    controller.openTrash();
    await controller.refreshTrash();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            height: 425,
            child: TrashOverlay(
                controller: controller, onClose: controller.closeTrash),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '行尾多了日期与按钮，240dp 上不能挤爆');
  });

  testWidgets('长按菜单：恢复 + 彻底删除（二次确认只删一条）', (tester) async {
    final controller = await build();
    final ids = [for (final t in controller.tasks) t.id];
    await controller.deleteTask(ids.first);
    await controller.deleteTask(ids.last);
    controller.openTrash();
    await controller.refreshTrash();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TrashOverlay(controller: controller, onClose: controller.closeTrash),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('甲'));
    await tester.pumpAndSettle();
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('彻底删除'), findsOneWidget);

    await tester.tap(find.text('彻底删除'));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(controller.trashEntries.length, 1);
    expect(controller.tasks, isEmpty, reason: '真删的那条不回清单');
  });
}
