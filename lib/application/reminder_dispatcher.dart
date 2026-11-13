import 'dart:async';

import '../domain/event.dart';
import '../domain/plan.dart';
import '../domain/reminder.dart';
import '../domain/task.dart';
import 'delivery.dart';
import 'notification_window.dart';
import 'plan_service.dart';
import 'task_service.dart';

/// 站点表协调者（§4.3）：重锚一次把能预排的站全交给 AlarmPort。
///
/// 流向：TaskService 重锚（scheduleReanchored）/ PlanService 变更（changes）→
/// alarm.cancel() → 算出三个提醒源的站点表 → alarm.scheduleStations()；
/// alarm.fired → （编排那一站直接弹）TaskService.pollReminder() →
/// NotificationPort.show(...) → 重锚覆盖整表。
///
/// 时点提醒与编排是静态站，一次排全；软提醒按裕度动态调频，只放当下算出的
/// 那一站。安卓把表存进原生 prefs 并逐站挂进 AlarmManager，开机自行恢复，
/// 所以应用不在时静态站照常到点投递（docs/sockets/delivery.md）。
///
/// 三个提醒源：
/// - **Slack 软提醒**（截止型任务）：经 [windows] 送达策略（段外顺延到下一段开头）；
/// - **时点性提醒**（开始型到点 + 设了响的周期实例 + 无排序档的两站）：原样响，
///   不受静默段限制；任务自己的 metadata `alarm` 打开时升级为闹钟渠道
///   （全屏 + 持续响铃），覆盖掉它本该走的那条通知栏投递；
/// - **编排条目**（`编排.md` 里有时间的一行）：准点发一条静音消息，没有按钮、不升级
///   成闹钟、不套送达策略——它说的是"到我打算动手的点了"，不是催办
///   （决定卡 2026-10-29-plan-reminder）。
///
/// **渠道只看两件事**：这条是不是时点提醒（能不能升级成闹钟）+ 任务自己的
/// metadata `alarm`。调度模式不参与——两档都提醒。普通提醒一律有声（通知栏 +
/// 横幅 + 提示音 + 震动）；只有编排条目恒静音。
class ReminderDispatcher {
  final TaskService service;
  final AlarmPort alarm;
  final NotificationPort notifications;

  /// 编排（第三个提醒源）。null = 不挂编排提醒（未装配的壳 / 测试）。
  final PlanService? plans;

  /// 通知时间段（设置页编辑后经装配点同步，§4.3）。
  NotificationWindowRule windows;

  /// 持续响铃通道（§7.2）。null = 这套壳没有它（桌面 / 测试）：只投通知、不起铃。
  final AlarmRingPort? ring;

  /// 响铃时长（秒）：设置项 `alarm_ring_seconds` 由装配点推进来，起铃那一刻才读。
  int ringSeconds;

  /// 本分钟已经起过闹钟的那一分钟，以及那条正文里已经列过的任务。
  /// 同一分钟的后来者只留普通通知——全屏页同一刻只能有一个抢到前台。
  DateTime? _alarmMinute;
  Set<String> _alarmCovered = const {};

  static const List<NotificationAction> defaultActions = [
    NotificationAction(id: 'done', label: '完成'),
    NotificationAction(id: 'snooze1h', label: '推迟 1 小时'),
  ];

  StreamSubscription<DomainEvent>? _events;
  StreamSubscription<FiredAlarm>? _fires;
  StreamSubscription<void>? _planChanges;

  /// 重挂串行链：事件流、设置变更、到点回调会同时打进来，只让最新的一次真正
  /// 动闹钟。两次重挂交错时，后读到旧调度结果的那次会覆盖新挂的那一站。
  Future<void> _rescheduleChain = Future.value();
  int _rescheduleGen = 0;

  /// 到点回调串行链：应用被杀期间攒下的 alarmFired 会在 drainEvents 里一次性
  /// 灌进来；并发跑会被 TaskService 的不可重入锁吞掉，后面的几条连记账都做不了。
  Future<void> _firedChain = Future.value();

  /// 表里每一条编排站，按站点 id 认人（到点回传的是 id）。
  Map<String, PlanReminder> _planStations = const {};

  ReminderDispatcher({
    required this.service,
    required this.alarm,
    required this.notifications,
    this.plans,
    this.ring,
    this.windows = NotificationWindowRule.defaultRule,
    this.ringSeconds = 60,
  }) {
    // 轮询那一侧也要按同一份规则判"能不能打扰"，否则前台 tick 会绕过静默段。
    service.updateDeliveryWindows(windows);
  }

  /// 设置页改了送达策略：换规则并按新规则重挂站点表。
  Future<void> updateWindows(NotificationWindowRule rule) async {
    windows = rule;
    service.updateDeliveryWindows(rule);
    await _reschedule();
  }

  /// 设置页改了响铃时长：**要重挂一次**。
  ///
  /// 应用被杀时起铃的是原生接收器，它只能读挂闹钟那一刻写进草案的秒数（`settings.json`
  /// 只有 Dart 读得到）。不重挂的话，改完设置到下一次重锚之间的那几条仍按旧时长响。
  Future<void> updateRingSeconds(int seconds) async {
    if (seconds == ringSeconds) return;
    ringSeconds = seconds;
    await _reschedule();
  }

  Future<void> start() async {
    _events ??= service.events.listen((e) {
      if (e.type == DomainEventType.scheduleReanchored) {
        _reschedule();
      }
    });
    // 编排变了就重挂：代理不到这一层，条目加了/改了时刻这边不会自己知道。
    _planChanges ??= plans?.changes.listen((_) => _reschedule());
    _fires ??= alarm.fired.listen(_onFired);
    await _reschedule();
  }

  Future<void> dispose() async {
    await _events?.cancel();
    await _fires?.cancel();
    await _planChanges?.cancel();
    await _firedChain;
    await _rescheduleChain;
    await alarm.cancel();
  }

  /// 排一次重挂。并发时只保留最新的一次：链上排队的旧请求直接跳过，省得
  /// "取消旧的、挂新的"两步被别的重挂插进来拆开。
  Future<void> _reschedule() {
    final gen = ++_rescheduleGen;
    _rescheduleChain = _rescheduleChain.then((_) async {
      if (gen != _rescheduleGen) return;
      await _rescheduleNow();
    }).catchError((Object _) {
      // 挂不上闹钟不该让后面的重挂全部停摆：这一站丢了，下一次事件会再算一遍。
    });
    return _rescheduleChain;
  }

  Future<void> _rescheduleNow() async {
    final current = service.now();
    final s = service.lastSchedule;
    await alarm.cancel();
    final manual = service.isManualSort;
    final candidates = <_StationCandidate>[];
    final planStations = <String, PlanReminder>{};

    // 编排：未来每一站都是静态的，一次排全。同一分钟共用一个 id（PlanService
    // 已合并过），按 id 记下正文，到点回传时好认人。
    for (final p in plans?.allReminders(current) ?? const <PlanReminder>[]) {
      planStations[p.id] = p;
      candidates.add(_StationCandidate(
        at: p.at,
        priority: 0,
        draft: ReminderDraft(
          taskId: p.id,
          title: p.title,
          body: _planBody(p),
          channel: ReminderChannel.silent,
        ),
      ));
    }
    _planStations = planStations;

    // 软提醒：按裕度动态调频，下一站要重算才知道，表里只放当下这一站。送达策略
    // 只顺延这一支；时点提醒与编排都不吃静默段。无排序档没有软提醒。
    final softAt = manual ? null : s?.nextReminderAt;
    final softId = manual ? null : s?.nextReminderTaskId;
    if (softAt != null && softId != null) {
      final task = service.byId(softId);
      candidates.add(_StationCandidate(
        at: windows.resolveDelivery(softAt),
        priority: 1,
        draft: ReminderDraft(
          taskId: softId,
          title: task?.title ?? '该做这件事了',
          body: _bodyOf(task),
          channel: ReminderChannel.ring,
          actions: defaultActions,
        ),
      ));
    }

    // 时点提醒：每一件未来会响的站都排上。应用不在时由原生照表逐站投递，
    // 正文里的「接下来」与「同时还有」此刻就要带上——到点没有 Dart 可问。
    for (final p in service.allPointReminders()) {
      final task = service.byId(p.taskId);
      final alarmOn = _channelFor(task, point: true) == ReminderChannel.alarm;
      candidates.add(_StationCandidate(
        at: p.at,
        priority: 2,
        draft: ReminderDraft(
          taskId: p.taskId,
          title: task?.title ?? '该做这件事了',
          body: _bodyFor(task, alarm: alarmOn, at: p.at),
          channel: alarmOn ? ReminderChannel.alarm : ReminderChannel.ring,
          fullScreen: alarmOn,
          actions: defaultActions,
        ),
      ));
    }

    // 同一时刻只留一个站，优先级沿用旧口径：编排 → 软提醒 → 时点。
    final byMoment = <int, _StationCandidate>{};
    for (final c in candidates) {
      final key = c.at.millisecondsSinceEpoch;
      final prev = byMoment[key];
      if (prev == null || c.priority < prev.priority) byMoment[key] = c;
    }
    final ordered = byMoment.values.toList()
      ..sort((a, b) => a.at.compareTo(b.at));

    // 表是重锚那一刻的快照，别把半年后的站全挂上：7 天 / 40 站，超出的由
    // 下一次重锚补。已过时刻推到 now+1s（时点提醒有 30 分钟补响宽限，原样交给
    // AlarmManager 会立即触发，point_fired 没写成就会绕成短循环）。
    final horizon = current.add(const Duration(days: 7));
    final stations = <AlarmStation>[];
    for (final c in ordered) {
      if (stations.length >= 40 || c.at.isAfter(horizon)) break;
      final at = c.at.isAfter(current)
          ? c.at
          : current.add(const Duration(seconds: 1));
      stations.add(AlarmStation(at: at, draft: c.draft));
    }
    await alarm.scheduleStations(stations);
  }

  /// 到点事件排队执行：drainEvents 会一次性灌进多条，串行跑才不会互相吞掉。
  void _onFired(FiredAlarm firing) {
    _firedChain = _firedChain.then((_) => _handleFired(firing)).catchError((Object _) {
      // 一条失败不该把后面排队的几条一起掐掉；下一次重锚会把账补回来。
    });
  }

  /// 闹钟到点。**投递只做一次**：安卓的原生接收器在回调之前就已经照着挂
  /// 闹钟时的草案弹了通知（应用被杀也照弹），所以 `delivered` 为真时这里
  /// 只记账并排下一站；再 show 一次就是同 id 替换 + 重新响铃，通知时刻被刷成
  /// "现在"——用户看到的就是"这条提醒晚了十几分钟"。
  ///
  /// 编排那一站不经过 `pollReminder`（那不是任务，没有可记账的状态）：照草案弹完就
  /// 排下一站。**同一时刻的任务提醒不受影响**——poll 照跑，撞在同一分钟时两条都到。
  Future<void> _handleFired(FiredAlarm firing) async {
    final planStation =
        isPlanReminderId(firing.taskId) ? _planStations[firing.taskId] : null;
    if (planStation != null && !firing.delivered) {
      await _showPlan(planStation);
    }
    final event = await service.pollReminder();
    // delivered 说的是"刚起来的那一站已经弹过了"，不是"这一趟什么都别弹"：
    // 编排那一站弹过了，同时到点的任务提醒还没弹，所以只在任务自己那一站上跳过。
    if (event != null && !(firing.delivered && planStation == null)) {
      await _showTask(event);
    }
    await _reschedule(); // 链路自续：排下一站（防 Zeno：只在事件里重排）
  }

  Future<void> _showTask(ReminderEvent event) async {
    final point = event.kind == ReminderKind.point;
    final task = service.byId(event.taskId);
    var channel = _channelFor(task, point: point);
    final now = service.now();
    if (channel == ReminderChannel.alarm) {
      final minute = DateTime(now.year, now.month, now.day, now.hour, now.minute);
      if (_alarmMinute == minute && _alarmCovered.contains(event.taskId)) {
        // 本分钟已经起过闹钟，这一件已在上一页的正文里露过面：只留普通通知。
        // 不影响它自己的 point_fired 与下一站。
        channel = ReminderChannel.ring;
      } else {
        _alarmMinute = minute;
        _alarmCovered = _sameMinuteAlarmIds(task, at: now);
        await ring?.start(event.taskId, seconds: ringSeconds);
      }
    }
    final alarmOn = channel == ReminderChannel.alarm;
    await notifications.show(
      event,
      actions: defaultActions,
      channel: channel,
      fullScreen: alarmOn,
      draft: ReminderDraft(
        taskId: event.taskId,
        title: task?.title ?? '该做这件事了',
        body: _bodyFor(task, alarm: alarmOn, at: now),
        channel: channel,
        fullScreen: alarmOn,
        actions: defaultActions,
      ),
    );
  }

  /// 编排条目：一条消息，没有按钮、不接闹钟模式（即使设置里开着）。
  Future<void> _showPlan(PlanReminder station) async {
    final draft = ReminderDraft(
      taskId: station.id,
      title: station.title,
      body: _planBody(station),
      channel: ReminderChannel.silent,
    );
    await notifications.show(
      ReminderEvent(
        firedAt: service.now(),
        taskId: station.id,
        kind: ReminderKind.point,
      ),
      channel: ReminderChannel.silent,
      draft: draft,
    );
  }

  /// 一条提醒走哪个渠道：**只有时点提醒能升级成闹钟**，任务自己不一定要
  /// （metadata `alarm`，缺键 = 不开）。截止型的软提醒一律普通通知。
  /// 任务查不到时按普通提醒走——没有主人的提醒不该全屏吵人。
  ReminderChannel _channelFor(Task? task, {required bool point}) {
    if (!point) return ReminderChannel.ring;
    return (task?.alarmEnabled ?? false)
        ? ReminderChannel.alarm
        : ReminderChannel.ring;
  }

  String? _bodyOf(Task? task) {
    if (task == null) return null;
    final d = task.deadline;
    if (task.type == TaskType.flex) {
      // 无排序档不问工时，报"剩余 N 分钟"是拿缺省 30 分钟编出来的——只报截止。
      if (service.isManualSort) {
        return d == null ? null : '截止 ${_fmt(d)}';
      }
      // '长期'任务没有剩余工时（D18），也不会走到提醒链路（无截止 → 无锚点）；
      // ?? 0 只是让展示文案对空值安全。
      final remaining = task.remainingWork ?? 0;
      if (remaining > 0) {
        return d == null
            ? '剩余约 $remaining 分钟'
            : '截止 ${_fmt(d)} · 剩余约 $remaining 分钟';
      }
    }
    if (d != null) {
      return task.type == TaskType.fixed ? '开始 ${_fmt(d)}' : '到点 ${_fmt(d)}';
    }
    return null;
  }

  /// 闹钟正文：基础正文后面追两段（§7.2）。两段都只是文案，不参与排站、
  /// 不改变谁响——后面的件到点仍各自响各自的闹钟。
  String? _bodyFor(Task? task, {required bool alarm, required DateTime at}) {
    final base = _bodyOf(task);
    if (!alarm || task == null) return base;
    final parts = <String>[
      ?base,
      ..._alarmCompanions(task, at: at),
    ];
    return parts.isEmpty ? base : parts.join('\n');
  }

  /// 同时还有什么 / 接下来还有什么。
  ///
  /// 同一分钟的并排列出：全屏页同一刻只能有一个，先到的那个负责把同刻的几件
  /// 报全。3 小时内但不同刻的排在"接下来"，最多 3 条，超出只报件数。
  List<String> _alarmCompanions(Task self, {required DateTime at}) {
    final minute =
        DateTime(at.year, at.month, at.day, at.hour, at.minute);
    final until = at.add(const Duration(hours: 3));
    final sameMinute = <String>[];
    final upcoming = <({Task task, DateTime at})>[];
    for (final t in service.tasks) {
      if (t.id == self.id || !t.alarmEnabled) continue;
      final when = t.pointReminderAt;
      if (when == null) continue;
      if (DateTime(when.year, when.month, when.day, when.hour, when.minute) ==
          minute) {
        sameMinute.add(t.title);
      } else if (when.isAfter(at) && !when.isAfter(until)) {
        upcoming.add((task: t, at: when));
      }
    }
    final out = <String>[];
    if (sameMinute.isNotEmpty) {
      out.add('同时还有：${sameMinute.join('、')}');
    }
    if (upcoming.isNotEmpty) {
      upcoming.sort((a, b) => a.at.compareTo(b.at));
      final shown = upcoming
          .take(3)
          .map((e) => '${e.task.title} ${_two(e.at.hour)}:${_two(e.at.minute)}')
          .join('、');
      final more = upcoming.length > 3 ? '，等 ${upcoming.length} 件' : '';
      out.add('接下来：$shown$more');
    }
    return out;
  }

  /// 本分钟里所有开着闹钟的时点提醒。第一条起铃时记下它们，后面同一分钟的
  /// 事件就只留普通通知——不再起第二个全屏页、不叠第二股铃声。
  Set<String> _sameMinuteAlarmIds(Task? self, {required DateTime at}) {
    final minute =
        DateTime(at.year, at.month, at.day, at.hour, at.minute);
    final ids = <String>{};
    for (final t in service.tasks) {
      if (!t.alarmEnabled) continue;
      final when = t.pointReminderAt;
      if (when == null) continue;
      if (DateTime(when.year, when.month, when.day, when.hour, when.minute) ==
          minute) {
        ids.add(t.id);
      }
    }
    if (self != null) ids.add(self.id);
    return ids;
  }

  /// 编排条目的正文：只报"哪天几点"，不写"剩余"这一类调度量（条目没有工时）。
  static String _planBody(PlanReminder station) =>
      '编排 ${_fmt(station.at)}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime d) =>
      '${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// 排站时的临时候选：同一时刻按 priority 挑一个（编排 0 / 软提醒 1 / 时点 2）。
class _StationCandidate {
  final DateTime at;
  final int priority;
  final ReminderDraft draft;

  const _StationCandidate({
    required this.at,
    required this.priority,
    required this.draft,
  });
}
