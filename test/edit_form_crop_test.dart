import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/settings.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/dialogs/edit_task_sheet.dart';

/// 编辑表单按档裁行（ui-interaction.md §5.1 / §7.0）：无排序档只留『工作强度』，
/// 预计工时与重要度都不出现——这一档不跑公式、提醒也不看工时，填了没有去处。
///
/// 同时锁住"隐藏不等于清空"：在这两行不显示的情况下保存，工时与重要度必须原样
/// 保留，不能被缺省值冒名顶替。
void main() {
  Future<AppController> boot(
    WidgetTester tester, {
    required ScheduleMode mode,
    bool askImportance = false,
  }) async {
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 7, 10, 0),
    );
    final controller = AppController(
      service: svc,
      taskDir: 'ignored',
      settingsPort: _MemorySettingsPort(
        AppSettings.defaults.copyWith(
          guideSeen: true,
          scheduleMode: mode,
          askImportance: askImportance,
        ),
      ),
    );
    await tester.runAsync(controller.bootstrap);
    await svc.createTask(
      title: '写周报',
      deadline: DateTime(2026, 10, 9, 18),
      estimatedWorkMinutes: 90,
      importance: 5,
    );
    return controller;
  }

  /// 把编辑表单直接当根页面挂起来（不经过列表与长按菜单）。
  Future<void> openEdit(WidgetTester tester, AppController c) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showEditSheet(context, c, task: c.tasks.single),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('无排序档：工作强度留着，工时与重要度都不出现', (tester) async {
    final c = await boot(tester, mode: ScheduleMode.manual);
    await openEdit(tester, c);

    expect(find.text('工作强度'), findsOneWidget, reason: '这一档仍能标长期');
    expect(find.text('预计工时（分钟）'), findsNothing);
    expect(find.text('重要度'), findsNothing);
    expect(find.text('响铃'), findsOneWidget);
  });

  testWidgets('无排序档保存不动被藏起来的两个值', (tester) async {
    final c = await boot(tester, mode: ScheduleMode.manual);
    await openEdit(tester, c);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final task = c.tasks.single;
    expect(task.estimatedWork, 90, reason: '工时只是不显示，不该被写成缺省 30');
    expect(task.importance, 5, reason: '重要度同理');
  });

  testWidgets('标准档问工时；重要度跟着『问重要度』开关', (tester) async {
    final c = await boot(
      tester,
      mode: ScheduleMode.standard,
      askImportance: true,
    );
    await openEdit(tester, c);

    expect(find.text('工作强度'), findsOneWidget);
    expect(find.text('预计工时（分钟）'), findsOneWidget);
    expect(find.text('重要度'), findsOneWidget);
  });

  testWidgets('标准档关掉『问重要度』：只有工时那一行少重要度', (tester) async {
    final c = await boot(tester, mode: ScheduleMode.standard);
    await openEdit(tester, c);

    expect(find.text('工作强度'), findsOneWidget);
    expect(find.text('预计工时（分钟）'), findsOneWidget);
    expect(find.text('重要度'), findsNothing);
  });
}

class _MemorySettingsPort implements SettingsPort {
  AppSettings current;

  _MemorySettingsPort(this.current);

  @override
  Future<AppSettings> load() async => current;

  @override
  Future<void> save(AppSettings settings) async {
    current = settings;
  }
}
