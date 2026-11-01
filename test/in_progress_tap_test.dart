import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/today_panel.dart';
import 'package:qixing/ui/widgets/task_selection.dart';

/// 挂起组点按 = **今天做过**（决议 47，决定卡 2026-10-31-suspend-daily-habit）：
/// 清掉今天这一挂、把这件搬回任务池（`loose_home`），不弹详情卡；
/// 长按菜单给的是『不再每日挂起』——彻底退出每日循环的那一条。
void main() {
  Future<AppController> build() async {
    final tmp = Directory.systemTemp.createTempSync('gtd_in_progress_tap');
    addTearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    // 内存仓储：改数据要走真文件的话，widget 测试里的 await 永远等不到
    // （真实 IO 不跑在 FakeAsync 里，得包 runAsync），点按那条通路就测不出来。
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      scheduleMode: ScheduleMode.manual,
    );
    final t = await svc.createTask(title: '练琴');
    await svc.setInProgress(t.id, enabled: true);
    final controller = AppController(service: svc, taskDir: tmp.path);
    await controller.updateSettings(
      controller.settings.copyWith(scheduleMode: ScheduleMode.manual),
    );
    return controller;
  }

  /// 与生产装配一致：面板外面套一层听控制器的 AnimatedBuilder（`SidePanel` 就是这么
  /// 挂的）——裸 TodayPanel 只听 selection，改完数据不会重建。
  Future<void> pump(WidgetTester tester, AppController controller,
      TaskSelection selection) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (_, _) =>
              TodayPanel(controller: controller, selection: selection),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('点一下 = 今天做过：离开挂起组、搬回任务池，不弹详情卡', (tester) async {
    final controller = await build();
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await pump(tester, controller, selection);
    expect(find.text('挂起进行'), findsOneWidget);
    expect(find.text('练琴'), findsOneWidget);
    expect(find.text('散件'), findsNothing, reason: '挂着的时候它只在 ⓿');

    await tester.tap(find.text('练琴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('不排期'), findsNothing, reason: '点按不弹详情卡');
    expect(find.textContaining('今天做过'), findsOneWidget, reason: '顺手给一句反馈');
    expect(find.text('挂起进行'), findsNothing, reason: '今天这一挂结束了');
    expect(find.text('散件'), findsNothing,
        reason: '不留今日页 ⑥：点掉的长期件搬去任务池，明天由挂起组收回来');
    expect(find.text('练琴'), findsNothing, reason: '本页上不再有它');

    final task = controller.poolView.loose.single;
    expect(task.looseHomeIsPool, isTrue, reason: '家搬到了池子散件段');
    expect(controller.todayView.loose, isEmpty);
    expect(task.inProgressAt, isNull);
    expect(task.inProgressDailyDate, isNotNull,
        reason: '每日回挂标记留着——明天早上还要挂回来');

    // 等 snackbar 自己走完，别把定时器留给测试收尾。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('长按挂起组：给『不再每日挂起』，没有『推迟』', (tester) async {
    final controller = await build();
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await pump(tester, controller, selection);
    await tester.longPress(find.text('练琴'));
    await tester.pumpAndSettle();

    expect(find.text('不再每日挂起'), findsOneWidget);
    expect(find.text('取消挂起'), findsNothing);
    expect(find.textContaining('推迟'), findsNothing,
        reason: '长期任务没有截止，没有可推迟的余地');

    await tester.tap(find.text('不再每日挂起'));
    await tester.pumpAndSettle();

    expect(find.text('挂起进行'), findsNothing);
    final task = controller.taskById(controller.todayView.loose.single.id)!;
    expect(task.inProgressAt, isNull);
    expect(task.inProgressDailyDate, isNull, reason: '彻底退出每日循环');
  });
}
