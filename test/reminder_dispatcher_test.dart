import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/delivery.dart';
import 'package:qixing/application/notification_window.dart';
import 'package:qixing/application/plan_service.dart';
import 'package:qixing/application/reminder_dispatcher.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/plan.dart';
import 'package:qixing/domain/reminder.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/platform/desktop_adapters.dart';
import 'package:qixing/repository/memory_plan_repository.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';

/// 假闹钟：记录预约，测试里手动触发 fired。
class _FakeAlarm implements AlarmPort {
  DateTime? scheduledAt;
  String? taskId;
  ReminderDraft? draft;
  int cancels = 0;
  final _fired = StreamController<FiredAlarm>.broadcast();

  @override
  Future<void> scheduleStations(List<AlarmStation> stations) async {
    scheduledAt = null;
    taskId = null;
    draft = null;
    if (stations.isEmpty) return;
    scheduledAt = stations.first.at;
    taskId = stations.first.id;
    draft = stations.first.draft;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Stream<FiredAlarm> get fired => _fired.stream;

  /// 触发一次到点。[delivered] = 系统侧已经弹过通知（安卓原生接收器）。
  /// [taskId] 用于模拟冷启动时一次性回放多条积压事件（那时挂的站早已换过）；
  /// [at]/[stationKey]/[draft] = 这一站的站点身份（原生 `alarmFired` 带回来的），
  /// 只给 [taskId] 等于桌面 Timer / 升级前入队的老事件。
  void fire({
    String? taskId,
    bool delivered = false,
    DateTime? at,
    String? stationKey,
    ReminderDraft? draft,
  }) {
    _fired.add(FiredAlarm(
      taskId ?? this.taskId ?? '',
      delivered: delivered,
      at: at,
      stationKey: stationKey,
      draft: draft,
    ));
  }
}

/// 一站的原生回传草案：标题可以故意与任务标题不同，好断言"弹的是那一站的草案"。
ReminderDraft _draftFor(String taskId, {String? title}) => ReminderDraft(
      taskId: taskId,
      title: title ?? taskId,
      body: '草案正文',
      actions: ReminderDispatcher.defaultActions,
    );

/// 假响铃端口：记录起铃与停铃。
class _FakeRing implements AlarmRingPort {
  final started = <({String taskId, int seconds})>[];
  final stopped = <String>[];
  String? _ringing;

  @override
  Future<void> start(String taskId, {required int seconds}) async {
    started.add((taskId: taskId, seconds: seconds));
    _ringing = taskId;
  }

  @override
  Future<void> stop(String taskId) async {
    stopped.add(taskId);
    if (_ringing == taskId) _ringing = null;
  }

  @override
  String? get ringingTaskId => _ringing;
}

/// 假通知端口：记录 show 调用。
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
    NotificationWindowRule windows = NotificationWindowRule.defaultRule,
    PlanService? plans,
    AlarmRingPort? ring,
    int ringSeconds = 60,
  }) async {
    final d = ReminderDispatcher(
      service: svc,
      alarm: alarm,
      notifications: notifications,
      plans: plans,
      ring: ring,
      windows: windows,
      ringSeconds: ringSeconds,
    );
    await d.start();
    return d;
  }

  /// 编排（第三个提醒源）：一天里排几条，挂进分发器。
  Future<PlanService> startPlans(List<PlanEntry> entries, {int day = 7}) async {
    final plans = PlanService(
      repo: MemoryPlanRepository([
        DayPlan(day: DateTime(2026, 10, day), entries: entries),
      ]),
    );
    await plans.load();
    return plans;
  }

  test('编排条目占站点：准点、静音、没有按钮（不吃通知时间段）', () async {
    // 晚间窗口 19:00–21:00：软提醒会被顺延，编排条目原样响。
    const evening =
        NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
    ]);
    await startDispatcher(windows: evening, plans: plans);

    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 0));
    expect(isPlanReminderId(alarm.taskId!), isTrue);
    expect(alarm.draft!.title, '项目评审');
    expect(alarm.draft!.body, '编排 10-07 17:00');
    expect(alarm.draft!.channel, ReminderChannel.silent);
    expect(alarm.draft!.actions, isEmpty, reason: '能推迟的是任务，编排只排不做');
  });

  test('编排到点 → 一条静音消息，然后排下一条', () async {
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
      PlanEntry(title: '写周报', minutesOfDay: 18 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 17, 0);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, hasLength(1));
    final shown = notifications.shownList.first;
    expect(shown.channel, ReminderChannel.silent);
    expect(shown.actions, isEmpty);
    expect(shown.draft!.title, '项目评审', reason: '条目没有任务可查，只能照草案渲染');
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 18, 0),
        reason: '响完这一站就排下一条');
  });

  test('编排与任务撞在同一刻：编排占站点，到点两条都弹', () async {
    final meeting = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 0),
    );
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);

    final planId = alarm.taskId!;
    expect(isPlanReminderId(planId), isTrue, reason: '同一刻编排先占站点');

    now = DateTime(2026, 10, 7, 17, 0);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final ids = notifications.shownList.map((s) => s.event.taskId).toList();
    expect(ids, containsAll(<String>[planId, meeting.id]));
  });

  test('编排条目改时刻 → 重挂下一站（变更信号）', () async {
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 0));

    await plans.addEntry(
      DateTime(2026, 10, 7),
      const PlanEntry(title: '提前的评审', minutesOfDay: 16 * 60 + 30),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 30));
    expect(alarm.draft!.title, '提前的评审');
  });

  test('重锚 → 挂唯一闹钟；默认送达窗口内原样时刻', () async {
    final d = await startDispatcher();
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0), // 2h 后
      estimatedWorkMinutes: 60,
    );
    // nextReminderAt = 16:30（默认窗口 9:00-21:00 内 → 原样）
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 30));
    expect(alarm.taskId, isNotNull);
    expect(alarm.cancels, greaterThanOrEqualTo(1));
    expect(d, isNotNull);
  });

  test('nextReminderAt 落在静默段 → 顺延到段首（不吞掉）', () async {
    // 用只有晚间段的窗口：nextReminderAt=16:30 落在段外 → 顺延到 19:00
    const evening = NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await startDispatcher(windows: evening);
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 19, 0));
  });

  test('顺延之后的软提醒不能挤掉更早的时点闹钟（比早晚要用送达时刻）', () async {
    // 软提醒锚点 16:30，被晚间窗口顺延到 19:00；时点提醒在 18:00。
    // 拿未顺延的 16:30 去比，会选中软提醒 → 今晚的闹钟被跳过。
    const evening = NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await startDispatcher(windows: evening);
    final soft = await svc.createTask(
      title: '软提醒',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    final meeting = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);

    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 18, 0));
    expect(alarm.taskId, meeting.id, reason: '时点提醒更早，先挂它');
    expect(alarm.taskId, isNot(soft.id));
  });

  test('闹钟到点 → pollReminder → NotificationPort.show 带 actions', () async {
    await startDispatcher();
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 16, 30); // 到点
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, hasLength(1));
    expect(notifications.shownList.first.event.schedule!.nextTaskId, isNotNull);
    expect(
      notifications.shownList.first.actions.map((a) => a.id),
      containsAll(['done', 'snooze1h']),
    );
  });

  test('到点但任务已不due（竞态）→ 重排而非误报', () async {
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);
    final scheduledBefore = alarm.scheduledAt;

    // 闹钟到点前任务已完成 → pollReminder 返回 null → 重新排程
    await svc.completeTask(a.id);
    now = scheduledBefore!.add(const Duration(minutes: 1));
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, isEmpty);
  });

  // 无排序档不跑调度（决定卡 mode-as-information-depth）：提醒是两站时点型
  // （提前一站 + 到点一站），所以它不吃通知时间段，也不按裕度节奏推下一轮。
  test('无排序档先挂提前那一站：即使落在静默段也原样响', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    const evening =
        NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await startDispatcher(windows: evening);
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);
    // 截止前 30 分钟 = 17:30，在晚间段之外——这一档不走送达策略
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 30));
    expect(alarm.taskId, a.id);
    expect(alarm.draft!.body, '截止 10-07 18:00', reason: '不问工时就不报剩余');
  });

  // 投递只做一次（§4.3）：安卓原生接收器在回调之前就弹过通知了。
  test('原生已投递时不 show：只记账 + 重排', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 30));

    // 应用被杀时原生弹过这一条，事件等下次启动 drainEvents 才补到 Dart
    now = DateTime(2026, 10, 7, 17, 55);
    alarm.fire(delivered: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, isEmpty,
        reason: '同 id 再投一次不是"无害替换"：会重新响铃、把通知时刻刷成现在');
    expect(svc.byId(a.id)!.pointFiredMark,
        DateTime(2026, 10, 7, 17, 30).toIso8601String(),
        reason: '幂等标记照样要落下，否则下次还会再响');
  });

  test('系统没弹成（权限被拒 / 桌面 Timer）时由 Dart 补投', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    await startDispatcher();
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
    );
    await Future<void>.delayed(Duration.zero);
    now = DateTime(2026, 10, 7, 17, 30);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notifications.shownList, hasLength(1));
  });

  test('无排序档：提前站早于创建 → 整站不排，只挂截止站', () async {
    await svc.updateScheduleMode(ScheduleMode.manual);
    await svc.updateManualLead(60);
    await startDispatcher();
    // 现在 16:00，截止 16:40：lead = 15:40 已经是过去 → 取截止 16:40
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 16, 40),
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 40));
    expect(alarm.taskId, a.id);
  });

  test('TimerAlarmPort 冒烟：过期时刻立即触发', () async {
    final port = TimerAlarmPort();
    final fired = port.fired.first.timeout(const Duration(seconds: 2));
    await port.scheduleStations([
      AlarmStation(
        at: DateTime.now().subtract(const Duration(minutes: 1)),
        draft: const ReminderDraft(taskId: 't1', title: '冒烟'),
      ),
    ]);
    expect((await fired).taskId, 't1');
    await port.cancel();
  });

  // 闹钟正文附带"后面还有什么"（§7.2）：只是文案，不改变谁响。
  test('闹钟正文带「接下来」：3 小时内其他开着闹钟的时点提醒', () async {
    await startDispatcher();
    final a = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 19, 0),
    );
    await svc.setTaskAlarm(a.id, enabled: true);
    final b = await svc.createTask(
      title: '复盘',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 20, 30),
    );
    await svc.setTaskAlarm(b.id, enabled: true);
    final c = await svc.createTask(
      title: '夜跑',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 23, 0),
    );
    await svc.setTaskAlarm(c.id, enabled: true);
    await Future<void>.delayed(Duration.zero);

    expect(alarm.taskId, a.id, reason: '下一站是最早的那件');
    expect(alarm.draft!.body, contains('接下来：复盘 20:30'));
    expect(alarm.draft!.body, isNot(contains('夜跑')),
        reason: '超出 3 小时的不列，免得清单变成一整天');
  });

  test('同一分钟的几件：第一个的正文并排列出其余件', () async {
    final ring = _FakeRing();
    await startDispatcher(ring: ring);
    final a = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 19, 0),
    );
    await svc.setTaskAlarm(a.id, enabled: true);
    final b = await svc.createTask(
      title: '站会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 19, 0),
    );
    await svc.setTaskAlarm(b.id, enabled: true);
    await Future<void>.delayed(Duration.zero);

    final draft = alarm.draft!;
    final other = draft.taskId == a.id ? '站会' : '例会';
    expect(draft.channel, ReminderChannel.alarm);
    expect(draft.body, contains('同时还有：$other'));

    now = DateTime(2026, 10, 7, 19, 0);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notifications.shownList, isNotEmpty);
    expect(notifications.shownList.first.channel, ReminderChannel.alarm,
        reason: '第一件起全屏响铃');
    expect(ring.started, hasLength(1), reason: '第一件起铃');

    // 同一分钟的第二件：通知照发，但降级成普通渠道，不叠第二股铃声。
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notifications.shownList.last.channel, ReminderChannel.ring,
        reason: '本分钟已经起过闹钟，这一件只在普通通知里留一条');
    expect(ring.started, hasLength(1),
        reason: '同一分钟只起一个全屏页、一股铃声；第二件不二次起铃');
  });

  // 持续响铃（ui-interaction §7.2）：铃是"现在就要你注意"，只给开了闹钟的时点提醒。
  test('开着闹钟的时点提醒到点 → 起铃，秒数取设置项', () async {
    final ring = _FakeRing();
    await startDispatcher(ring: ring, ringSeconds: 30);
    final a = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 19, 0),
    );
    await svc.setTaskAlarm(a.id, enabled: true);
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 19, 0);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ring.started.single.taskId, a.id);
    expect(ring.started.single.seconds, 30, reason: '设置里的响铃时长，不是写死的 60');
    expect(notifications.shownList.single.channel, ReminderChannel.alarm);
  });

  test('软提醒恒普通通知：任务开了闹钟也不起铃', () async {
    final ring = _FakeRing();
    await startDispatcher(ring: ring);
    final soft = await svc.createTask(
      title: '写周报',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    // 『闹钟』只对时点提醒生效；截止型的裕度提醒照旧走通知栏。
    await svc.setTaskAlarm(soft.id, enabled: true);
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 16, 30);
    alarm.fire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList.single.channel, ReminderChannel.ring);
    expect(ring.started, isEmpty, reason: '软提醒不许响铃');
  });

  test('改响铃时长 → 重挂一次：已挂的那条闹钟也要换成新秒数', () async {
    final d = await startDispatcher(ringSeconds: 30);
    final a = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 19, 0),
    );
    await svc.setTaskAlarm(a.id, enabled: true);
    await Future<void>.delayed(Duration.zero);
    final cancelsBefore = alarm.cancels;

    await d.updateRingSeconds(120);

    expect(d.ringSeconds, 120);
    expect(alarm.cancels, greaterThan(cancelsBefore),
        reason: '原生接收器只能读挂闹钟时写下的秒数，不重挂就还是旧时长');
    expect(alarm.taskId, a.id, reason: '重挂的是同一站，不改变谁响、也不改变时刻');
  });

  // 送达策略不只作用于系统闹钟：前台 20 秒 tick 走的是同一个 pollReminder。
  test('静默段内前台轮询不弹软提醒：与挂闹钟共用同一份送达策略', () async {
    const evening =
        NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await startDispatcher(windows: evening);
    await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 19, 0),
        reason: '原始锚点 16:30 落在段外，闹钟顺延到 19:00');

    now = DateTime(2026, 10, 7, 16, 30);
    expect(await svc.pollReminder(), isNull,
        reason: 'tick 不能照原始锚点在静默段把事件产出来');

    now = DateTime(2026, 10, 7, 19, 0);
    final event = await svc.pollReminder();
    expect(event, isNotNull);
    expect(event!.kind, ReminderKind.soft);
  });

  test('改通知时间段：service 与分发器拿到同一份规则', () async {
    final d = await startDispatcher();
    const evening =
        NotificationWindowRule([NotificationWindow(19 * 60, 21 * 60)]);
    await d.updateWindows(evening);
    expect(
      svc.deliveryWindows.resolveDelivery(DateTime(2026, 10, 7, 16, 30)),
      DateTime(2026, 10, 7, 19, 0),
    );
  });

  test('补响宽限内的过去站：挂到 now+1s，不把过期时刻交给闹钟', () async {
    final d = await startDispatcher();
    await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 16, 30),
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 30));

    now = DateTime(2026, 10, 7, 16, 35); // 已过 5 分钟，仍在 30 分钟宽限内
    await d.updateWindows(NotificationWindowRule.defaultRule);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 35, 1));
  });

  test('连续重挂并发：只真正动一次闹钟，最终留下最新的一站', () async {
    final d = await startDispatcher(ringSeconds: 30);
    await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 19, 0),
    );
    await Future<void>.delayed(Duration.zero);
    final before = alarm.cancels;

    await Future.wait([
      d.updateWindows(const NotificationWindowRule(
          [NotificationWindow(9 * 60, 12 * 60)])),
      d.updateWindows(NotificationWindowRule.defaultRule),
      d.updateRingSeconds(120),
    ]);

    expect(d.ringSeconds, 120);
    expect(alarm.cancels, lessThanOrEqualTo(before + 1),
        reason: '三次排进同一条链，旧请求跳过，只有最新一次真的取消重挂');
    expect(alarm.taskId, isNotNull);
  });

  test('冷启动连续回放多条到点事件：逐条记账，不被不可重入锁吞掉', () async {
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 50),
    );
    final b = await svc.createTask(
      title: 'B',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 55),
    );
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 18, 0); // 两站都过了，且都在补响宽限内
    alarm.fire(taskId: a.id);
    alarm.fire(taskId: b.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, hasLength(2));
    expect(notifications.shownList.map((s) => s.event.taskId),
        containsAll(<String>[a.id, b.id]));
  });

  // 到点事件带站点身份（docs/sockets/reminder.md）：按**这一站**记账与补投。
  test('回放单条事件只记它自己那一站，不替别的站记账', () async {
    await startDispatcher();
    final b = await svc.createTask(
      title: 'B',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 40),
    );
    final a = await svc.createTask(
      title: 'A',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 50),
    );
    await Future<void>.delayed(Duration.zero);

    // B@17:40 那站的闹钟被 ROM 吞了，只有 A@17:50 响了，当时应用不在。
    // 按"现在"重算会认成最早的 B：B 被记成已响（以后不再提醒），
    // A 却没记上（宽限窗口内会再响一遍）。
    final at = DateTime(2026, 10, 7, 17, 50);
    now = DateTime(2026, 10, 7, 18, 0);
    alarm.fire(
      taskId: a.id,
      delivered: true,
      at: at,
      stationKey: '${a.id}@${at.millisecondsSinceEpoch}',
      draft: _draftFor(a.id),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, isEmpty, reason: '原生已经弹过，不再 show');
    expect(svc.byId(a.id)!.pointFiredMark, at.toIso8601String(),
        reason: '记的是这一站的原定时刻，不是"现在"');
    expect(svc.byId(b.id)!.pointFiredMark, isNull,
        reason: '没响的那一站不能替它记账');
  });

  test('冷启动回放多条带站点身份的事件：各按自己的站补投', () async {
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 50),
    );
    final b = await svc.createTask(
      title: 'B',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 55),
    );
    await Future<void>.delayed(Duration.zero);

    final atA = DateTime(2026, 10, 7, 17, 50);
    final atB = DateTime(2026, 10, 7, 17, 55);
    now = DateTime(2026, 10, 7, 18, 0);
    // 两条都没弹成（渠道被关 / 前台服务起不来）：照各自的草案补投，
    // 内容取自挂站那一刻，而不是"现在"重算出来的那一件。
    alarm.fire(taskId: a.id, at: atA, draft: _draftFor(a.id, title: 'A 的站'));
    alarm.fire(taskId: b.id, at: atB, draft: _draftFor(b.id, title: 'B 的站'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      notifications.shownList.map((s) => s.draft!.title),
      ['A 的站', 'B 的站'],
    );
    expect(notifications.shownList.map((s) => s.event.taskId), [a.id, b.id]);
    expect(svc.byId(a.id)!.pointFiredMark, atA.toIso8601String());
    expect(svc.byId(b.id)!.pointFiredMark, atB.toIso8601String());
  });

  test('同一站重复回放：只补投一次，标记不倒退', () async {
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 50),
    );
    await Future<void>.delayed(Duration.zero);

    final at = DateTime(2026, 10, 7, 17, 50);
    now = DateTime(2026, 10, 7, 17, 55);
    alarm.fire(taskId: a.id, at: at, draft: _draftFor(a.id));
    alarm.fire(taskId: a.id, at: at, draft: _draftFor(a.id));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, hasLength(1), reason: '同 id 再弹会重新响铃');
  });

  test('编排站回放：没投过照草案补一条，投过只排下一站', () async {
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
      PlanEntry(title: '写周报', minutesOfDay: 18 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);

    final first = alarm.draft!;
    final firstId = alarm.taskId!;
    expect(first.title, '项目评审');

    now = DateTime(2026, 10, 7, 17, 5);
    alarm.fire(
      taskId: firstId,
      delivered: true,
      at: DateTime(2026, 10, 7, 17, 0),
      draft: first,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notifications.shownList, isEmpty, reason: '原生已经弹过');

    // 重锚后表里只剩下一站（条目没有 point_fired，不靠记账推进）。
    final next = alarm.draft!;
    now = DateTime(2026, 10, 7, 18, 0);
    alarm.fire(
      taskId: alarm.taskId!,
      at: DateTime(2026, 10, 7, 18, 0),
      draft: next,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList.single.draft!.title, '写周报');
    expect(notifications.shownList.single.channel, ReminderChannel.silent);
  });

  test('编排与任务撞在同一刻（带站点身份）：任务那一站由重锚挂到下一秒', () async {
    final meeting = await svc.createTask(
      title: '例会',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 0),
    );
    final plans = await startPlans(const [
      PlanEntry(title: '项目评审', minutesOfDay: 17 * 60),
    ]);
    await startDispatcher(plans: plans);
    await Future<void>.delayed(Duration.zero);

    final planDraft = alarm.draft!;
    expect(isPlanReminderId(planDraft.taskId), isTrue, reason: '同一刻编排先占站点');

    now = DateTime(2026, 10, 7, 17, 0);
    alarm.fire(
      taskId: planDraft.taskId,
      delivered: true,
      at: DateTime(2026, 10, 7, 17, 0),
      draft: planDraft,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList, isEmpty, reason: '编排那一条原生已经弹过');
    expect(alarm.taskId, meeting.id, reason: '落选的任务站不在表里，不能丢');
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 17, 0, 1),
        reason: '重锚把过点的站推到 now+1s，晚一秒照常到点');
  });

  test('软提醒那一站响过：不吃 point_fired，锚点推进到下一站', () async {
    await startDispatcher();
    final soft = await svc.createTask(
      title: '写周报',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await Future<void>.delayed(Duration.zero);
    expect(alarm.scheduledAt, DateTime(2026, 10, 7, 16, 30));
    final draft = alarm.draft!;

    now = DateTime(2026, 10, 7, 16, 35);
    alarm.fire(
      taskId: soft.id,
      delivered: true,
      at: DateTime(2026, 10, 7, 16, 30),
      draft: draft,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(svc.byId(soft.id)!.pointFiredMark, isNull,
        reason: '软提醒没有"已响那一站"这个标记');
    expect(notifications.shownList, isEmpty);
    expect(alarm.scheduledAt, isNotNull);
    expect(alarm.scheduledAt!.isAfter(now), isTrue, reason: '锚点已推进到下一轮');
  });

  test('只带时刻不带草案（站点信息不全）：退回旧路径，照常弹', () async {
    await startDispatcher();
    final a = await svc.createTask(
      title: 'A',
      type: TaskType.fixed,
      deadline: DateTime(2026, 10, 7, 17, 50),
    );
    await Future<void>.delayed(Duration.zero);

    now = DateTime(2026, 10, 7, 17, 55);
    alarm.fire(taskId: a.id, at: DateTime(2026, 10, 7, 17, 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications.shownList.single.event.taskId, a.id);
    expect(svc.byId(a.id)!.pointFiredMark,
        DateTime(2026, 10, 7, 17, 50).toIso8601String());
  });
}
