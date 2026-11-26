import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/daily_digest.dart';
import 'package:qixing/application/delivery.dart';
import 'package:qixing/application/notification_window.dart';
import 'package:qixing/application/reminder_dispatcher.dart';
import 'package:qixing/application/settings.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/reminder.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';

/// 假闹钟：记下整张站点表，测试里手动触发 fired。
class _FakeAlarm implements AlarmPort {
  List<AlarmStation> stations = const [];
  int cancels = 0;
  final _fired = StreamController<FiredAlarm>.broadcast();

  @override
  Future<void> scheduleStations(List<AlarmStation> next) async {
    stations = next;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Stream<FiredAlarm> get fired => _fired.stream;

  void fire({
    String? taskId,
    bool delivered = false,
    DateTime? at,
    String? stationKey,
    ReminderDraft? draft,
  }) {
    _fired.add(FiredAlarm(
      taskId ?? stations.first.id,
      delivered: delivered,
      at: at,
      stationKey: stationKey,
      draft: draft,
    ));
  }
}

class _FakeNotifications implements NotificationPort {
  final shownList = <ShownNotification>[];

  @override
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.ring,
    bool fullScreen = false,
    ReminderDraft? draft,
  }) async {
    shownList.add(ShownNotification(
      event: event,
      actions: actions,
      channel: channel,
      fullScreen: fullScreen,
      draft: draft,
    ));
  }

  @override
  Stream<ShownNotification> get shown => const Stream.empty();
}

void main() {
  late MemoryTaskRepository repo;
  late TaskService svc;
  late _FakeAlarm alarm;
  late _FakeNotifications notifications;
  var now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00

  setUp(() {
    repo = MemoryTaskRepository();
    now = DateTime(2026, 10, 7, 16, 0);
    svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => now,
    );
    alarm = _FakeAlarm();
    notifications = _FakeNotifications();
  });

  Future<ReminderDispatcher> startDispatcher({
    bool enabled = true,
    int minutes = defaultDailyReminderMinutes,
  }) async {
    final d = ReminderDispatcher(
      service: svc,
      alarm: alarm,
      notifications: notifications,
      windows: NotificationWindowRule.defaultRule,
      dailyReminderEnabled: enabled,
      dailyReminderMinutes: minutes,
    );
    await d.start();
    return d;
  }

  group('设置：daily_reminder_*', () {
    test('缺键 = 开、18:00；往返不丢；越界夹回一天之内', () {
      expect(AppSettings.defaults.dailyReminderEnabled, isTrue);
      expect(AppSettings.defaults.dailyReminderMinutes, 18 * 60);
      expect(AppSettings.fromJson({}).dailyReminderEnabled, isTrue);
      expect(AppSettings.fromJson({}).dailyReminderMinutes, 18 * 60);
      expect(
          AppSettings.fromJson({'daily_reminder_enabled': false})
              .dailyReminderEnabled,
          isFalse);
      expect(
          AppSettings.fromJson({'daily_reminder_minutes': 1290})
              .dailyReminderMinutes,
          1290);
      expect(
          AppSettings.fromJson({'daily_reminder_minutes': 9999})
              .dailyReminderMinutes,
          24 * 60 - 1);
      expect(
          AppSettings.fromJson({'daily_reminder_minutes': -5})
              .dailyReminderMinutes,
          0);
      expect(
          AppSettings.fromJson({'daily_reminder_minutes': 'x'})
              .dailyReminderMinutes,
          18 * 60);

      final back = decodeSettings(encodeSettings(const AppSettings(
        dailyReminderEnabled: false,
        dailyReminderMinutes: 7 * 60 + 5,
      )));
      expect(back.dailyReminderEnabled, isFalse);
      expect(back.dailyReminderMinutes, 7 * 60 + 5);
    });
  });

  group('算站：口径与时刻', () {
    test('只数今日页的编号条目：散件不算，没条目就不挂站', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await svc.createTask(title: '散件');
      // 散件在今日页 ⑥ 段（不是编号条目）→ 不算。
      expect(
        buildDailyDigest(
          tasks: svc.tasks,
          schedule: svc.lastSchedule,
          now: now,
          minutesOfDay: 18 * 60,
          scheduleMode: ScheduleMode.manual,
        ),
        isNull,
      );

      await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      final digest = buildDailyDigest(
        tasks: svc.tasks,
        schedule: svc.lastSchedule,
        now: now,
        minutesOfDay: 18 * 60,
        scheduleMode: ScheduleMode.manual,
      );
      expect(digest, isNotNull);
      expect(digest!.count, 1);
      expect(digest.title, '今天还剩 1 件');
      expect(digest.body, '写周报');
      expect(digest.at, DateTime(2026, 10, 7, 18, 0));
      expect(digest.id, 'daily|2026-10-07');
    });

    test('过点顺延明天；清单为空的那天到了也不挂', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      now = DateTime(2026, 10, 7, 19, 0);
      final digest = buildDailyDigest(
        tasks: svc.tasks,
        schedule: svc.lastSchedule,
        now: now,
        minutesOfDay: 18 * 60,
        scheduleMode: ScheduleMode.manual,
      );
      expect(digest!.at, DateTime(2026, 10, 8, 18, 0));
      expect(digest.id, 'daily|2026-10-08');
    });

    test('正文最多列三个标题，超出用省略号；按截止先后取', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      for (final (title, hour) in [
        ('C', 21),
        ('A', 19),
        ('D', 22),
        ('B', 20),
      ]) {
        await svc.createTask(
          title: title,
          deadline: DateTime(2026, 10, 7, hour, 0),
        );
      }
      final digest = buildDailyDigest(
        tasks: svc.tasks,
        schedule: svc.lastSchedule,
        now: now,
        minutesOfDay: 18 * 60,
        scheduleMode: ScheduleMode.manual,
      );
      expect(digest!.count, 4);
      expect(digest.title, '今天还剩 4 件');
      expect(digest.body, 'A、B、C…');
    });
  });

  group('站点表与到点', () {
    test('下一站就是收尾：18:00、普通渠道、没有按钮', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await startDispatcher();
      final task = await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      await Future<void>.delayed(Duration.zero);

      expect(alarm.stations.first.at, DateTime(2026, 10, 7, 18, 0));
      expect(alarm.stations.first.id, 'daily|2026-10-07');
      final draft = alarm.stations.first.draft;
      expect(draft.title, '今天还剩 1 件');
      expect(draft.body, '写周报');
      expect(draft.channel, ReminderChannel.ring);
      expect(draft.actions, isEmpty);
      expect(alarm.stations.map((s) => s.id), contains(task.id));
    });

    test('与任务站撞在同一分钟：往后挪一分钟，不丢这一条', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await startDispatcher();
      // 无排序档的任务有两站：截止前 30 分钟与截止那一刻。
      await svc.createTask(
        title: '交周报',
        deadline: DateTime(2026, 10, 7, 18, 0),
      );
      await Future<void>.delayed(Duration.zero);

      expect(alarm.stations.map((s) => s.at),
          contains(DateTime(2026, 10, 7, 18, 0)),
          reason: '任务自己那一站照旧占 18:00');
      final daily =
          alarm.stations.where((s) => isDailyDigestId(s.id)).single;
      expect(daily.at, DateTime(2026, 10, 7, 18, 1));
      expect(daily.draft.title, '今天还剩 1 件');
    });

    test('到点弹一条普通通知；随后重排，明天那一站已续上', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await startDispatcher();
      final task = await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      await Future<void>.delayed(Duration.zero);
      final station = alarm.stations.first;

      now = DateTime(2026, 10, 7, 18, 0);
      alarm.fire(
        taskId: station.id,
        at: station.at,
        stationKey: '${station.id}@${station.at.millisecondsSinceEpoch}',
        draft: station.draft,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notifications.shownList, hasLength(1));
      expect(notifications.shownList.single.event.taskId, 'daily|2026-10-07');
      expect(notifications.shownList.single.channel, ReminderChannel.ring);
      expect(notifications.shownList.single.draft!.title, '今天还剩 1 件');
      expect(alarm.stations.first.id, task.id,
          reason: '收尾响完，表头换回任务那一站');
      expect(alarm.stations.map((s) => s.id), contains('daily|2026-10-08'),
          reason: '明天那一站随重锚补上');
    });

    test('原生已投递时不重复弹', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await startDispatcher();
      await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      await Future<void>.delayed(Duration.zero);
      final station = alarm.stations.first;

      now = DateTime(2026, 10, 7, 18, 1);
      alarm.fire(
        taskId: station.id,
        delivered: true,
        at: station.at,
        draft: station.draft,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notifications.shownList, isEmpty);
    });

    test('关掉开关就不挂收尾站，任务自己的站照旧', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await startDispatcher(enabled: false);
      final task = await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      await Future<void>.delayed(Duration.zero);

      expect(alarm.stations.map((s) => s.id), isNot(contains('daily|2026-10-07')));
      expect(alarm.stations.first.id, task.id);
      expect(alarm.stations.first.at, DateTime(2026, 10, 7, 19, 30));
    });

    test('清单空了 → 那一站不挂', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await startDispatcher();
      final task = await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(alarm.stations.map((s) => s.id), contains('daily|2026-10-07'));

      await svc.completeTask(task.id);
      await Future<void>.delayed(Duration.zero);
      expect(alarm.stations.map((s) => s.id),
          isNot(contains('daily|2026-10-07')));
    });

    test('改时刻 → 重挂到新的那一站', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      final d = await startDispatcher();
      await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 23, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(alarm.stations.first.at, DateTime(2026, 10, 7, 18, 0));

      await d.updateDaily(enabled: true, minutes: 21 * 60);
      expect(alarm.stations.first.at, DateTime(2026, 10, 7, 21, 0));
      expect(alarm.stations.first.draft.title, '今天还剩 1 件');
    });

    test('桌面 Timer 只回站点 id：到点按当下重算一条', () async {
      await svc.updateScheduleMode(ScheduleMode.manual);
      await startDispatcher();
      await svc.createTask(
        title: '写周报',
        deadline: DateTime(2026, 10, 7, 20, 0),
      );
      await Future<void>.delayed(Duration.zero);

      now = DateTime(2026, 10, 7, 18, 0);
      alarm.fire(taskId: 'daily|2026-10-07');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 这一件在 18:00 之后就是逾期件，仍算今日页的编号条目。
      expect(notifications.shownList, hasLength(1));
      expect(notifications.shownList.single.draft!.title, '今天还剩 1 件');
    });
  });
}
