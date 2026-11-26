import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/app_locale.dart';
import 'package:qixing/ui/dialogs/task_detail_sheet.dart';
import 'package:qixing/ui/panels/pool_panel.dart';
import 'package:qixing/ui/panels/today_panel.dart';
import 'package:qixing/ui/widgets/task_selection.dart';
import 'package:qixing/ui/widgets/task_tile.dart';

/// 时间文案的宿主。`alwaysUse24HourFormat` 要在 MaterialApp **内部**覆盖——
/// 外层套一个 MediaQuery 会被 MaterialApp 自己的 `MediaQuery.fromView` 顶掉。
Widget clockHost({required bool use24, Widget? home}) => MaterialApp(
      locale: appLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24),
        child: inner ?? const SizedBox.shrink(),
      ),
      home: home ?? const SizedBox(key: ValueKey('clock-probe')),
    );

Future<BuildContext> clockContext(WidgetTester tester,
    {bool use24 = true}) async {
  await tester.pumpWidget(clockHost(use24: use24));
  return tester.element(find.byKey(const ValueKey('clock-probe')));
}

/// 行右端那一签（ui-interaction.md §8）：今日清单给时刻、任务池给日期；
/// 详情卡只剩标题 + 时间 + 备注。见 [决定 2026-10-28](../../docs/decisions/2026-10-28-tile-time-and-detail-slim.md)。
void main() {
  group('时间文案', () {
    final now = DateTime(2026, 10, 28, 9, 0);

    testWidgets('行内：同一天只给时刻，跨日只给日期', (tester) async {
      final ctx = await clockContext(tester);
      expect(
          fmtWhen(ctx, DateTime(2026, 10, 28, 18, 0),
              now: now, compact: true),
          '18:00');
      expect(
          fmtWhen(ctx, DateTime(2026, 10, 29, 14, 30),
              now: now, compact: true),
          '10-29');
      expect(
          fmtWhen(ctx, DateTime(2026, 10, 30, 18, 0),
              now: now, compact: true),
          '10-30');
    });

    testWidgets('跨年补两位年', (tester) async {
      final ctx = await clockContext(tester);
      expect(
          fmtWhen(ctx, DateTime(2027, 1, 5, 8, 0), now: now, compact: true),
          '27-01-05');
      expect(fmtDay(DateTime(2027, 1, 5), now: now), '27-01-05');
    });

    testWidgets('详情卡：同一天写"今天"', (tester) async {
      final ctx = await clockContext(tester);
      expect(
          fmtWhen(ctx, DateTime(2026, 10, 28, 18, 0), now: now), '今天 18:00');
      expect(
          fmtWhen(ctx, DateTime(2026, 10, 29, 14, 30), now: now), '明天 14:30');
    });

    testWidgets('任务池只要日期，不带时刻', (tester) async {
      expect(fmtDay(DateTime(2026, 10, 28, 18, 0), now: now), '10-28');
    });

    testWidgets('月末的次日跨到下个月', (tester) async {
      final ctx = await clockContext(tester);
      final eve = DateTime(2026, 10, 31, 20, 0);
      expect(
          fmtWhen(ctx, DateTime(2026, 11, 1, 9, 0), now: eve, compact: true),
          '11-01');
      expect(fmtWhen(ctx, DateTime(2026, 11, 1, 9, 0), now: eve), '明天 09:00');
    });

    testWidgets('12 小时制：分上午下午，且不留拉丁空格', (tester) async {
      final ctx = await clockContext(tester, use24: false);
      expect(
          fmtWhen(ctx, DateTime(2026, 10, 28, 18, 0),
              now: now, compact: true),
          '下午6:00');
      expect(
          fmtWhen(ctx, DateTime(2026, 10, 28, 9, 5),
              now: now, compact: true),
          '上午9:05');
      expect(fmtWhen(ctx, DateTime(2026, 10, 28, 0, 1), now: now),
          '今天 上午12:01');
    });
  });

  group('列表行', () {
    Future<AppController> build(WidgetTester tester) async {
      final tmp = Directory.systemTemp.createTempSync('gtd_tile_time');
      addTearDown(() {
        try {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final svc = TaskService(
        repo: MemoryTaskRepository(),
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        scheduleMode: ScheduleMode.manual,
      );
      final controller = AppController(service: svc, taskDir: tmp.path);
      await controller.updateSettings(
        controller.settings.copyWith(scheduleMode: ScheduleMode.manual),
      );
      return controller;
    }

    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(clockHost(use24: true, home: Scaffold(body: child)));
      await tester.pumpAndSettle();
    }

    testWidgets('今日清单：截止型行右端是时刻，不再有工时与逾期胶囊', (tester) async {
      final controller = await build(tester);
      final now = DateTime.now();
      await tester.runAsync(() async {
        await controller.createTask(
          title: '交周报',
          type: TaskType.flex,
          deadline: DateTime(now.year, now.month, now.day, 0, 1),
        );
      });
      final selection = TaskSelection();
      addTearDown(selection.dispose);

      await pump(
          tester, TodayPanel(controller: controller, selection: selection));
      expect(find.text('00:01'), findsOneWidget, reason: '同一天只给时刻');
      expect(find.text('30分'), findsNothing, reason: '工时不再进列表行');
      expect(find.text('已逾期'), findsNothing, reason: '逾期靠颜色与组头表达');
    });

    testWidgets('12 小时制：240dp 的行装得下「下午6:00」这一签', (tester) async {
      final controller = await build(tester);
      final now = DateTime.now();
      await tester.runAsync(() async {
        await controller.createTask(
          title: '把本周的进展整理成一页发给组里',
          type: TaskType.flex,
          deadline: DateTime(now.year, now.month, now.day, 18, 0),
        );
      });
      final selection = TaskSelection();
      addTearDown(selection.dispose);
      await tester.binding.setSurfaceSize(const Size(240, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(clockHost(
        use24: false,
        home: Scaffold(
            body: TodayPanel(controller: controller, selection: selection)),
      ));
      await tester.pumpAndSettle();

      expect(find.text('下午6:00'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '窄面板上不该溢出');
    });

    testWidgets('任务池：行右端是日期，不是时刻', (tester) async {
      final controller = await build(tester);
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1, 18, 0);
      await tester.runAsync(() async {
        await controller.createTask(
            title: '明天的事', type: TaskType.flex, deadline: tomorrow);
      });
      final selection = TaskSelection();
      addTearDown(selection.dispose);

      await pump(tester, PoolPanel(controller: controller, selection: selection));
      expect(find.text(fmtDay(tomorrow)), findsOneWidget);
      expect(find.text('18:00'), findsNothing, reason: '这一页不问几点');
    });

    testWidgets('详情卡：标题 + 时间 + 备注，没有动作按钮', (tester) async {
      final controller = await build(tester);
      final now = DateTime.now();
      final at = DateTime(now.year, now.month, now.day, 18, 0);
      late Task task;
      await tester.runAsync(() async {
        task = await controller.createTask(
          title: '交周报',
          type: TaskType.flex,
          deadline: at,
          description: '把本周的进展整理成一页。',
        );
      });

      await tester.pumpWidget(clockHost(
        use24: true,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showTaskDetailSheet(ctx, task),
              child: const Text('打开'),
            ),
          ),
        ),
      ));
      final ctx = tester.element(find.text('打开'));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('交周报'), findsOneWidget);
      expect(find.text('截止 ${fmtWhen(ctx, at)}'), findsOneWidget);
      expect(find.text('把本周的进展整理成一页。'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing, reason: '卡里不该有动作');
      expect(find.text('完成'), findsNothing);
    });
  });
}
