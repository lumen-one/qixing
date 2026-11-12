import 'dart:async';

import '../domain/event.dart';
import '../domain/plan.dart';
import '../domain/reminder.dart';
import '../domain/task.dart';
import 'delivery.dart';
import 'notification_window.dart';
import 'plan_service.dart';
import 'task_service.dart';

/// 单闹钟协调者（§4.3）：全局任一时刻只挂一个下一站闹钟。
///
/// 流向：TaskService 重锚（scheduleReanchored）/ PlanService 变更（changes）→
/// alarm.cancel() → 计算送达时刻 → alarm.scheduleNext()；
/// alarm.fired → （编排那一站直接弹）TaskService.pollReminder() →
/// NotificationPort.show(...)。
///
/// 适配器无自主权：只执行"取消旧的、挂新的"。
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

  /// 这一次挂的是编排那一站吗（不是就不碰任务）。
  PlanReminder? _planStation;

  ReminderDispatcher({
    required this.service,
    required this.alarm,
    required this.notifications,
    this.plans,
    this.ring,
    this.windows = NotificationWindowRule.defaultRule,
    this.ringSeconds = 60,
  });

  /// 设置页改了送达策略：换规则并按新规则重挂下一站闹钟。
  Future<void> updateWindows(NotificationWindowRule rule) async {
    windows = rule;
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
    await alarm.cancel();
  }

  Future<void> _reschedule() async {
    final s = service.lastSchedule;
    await alarm.cancel();
    _planStation = null;
    // 无排序档没有软提醒（不跑裕度），也不产出派生量；`s` 为 null 时只挂时点。
    // 那一档的截止型任务本身就走时点提醒这条链（截止前一次，见 nextPointReminder）。
    final manual = service.isManualSort;
    final point = service.nextPointReminder();
    final softAt = manual ? null : s?.nextReminderAt;
    final softId = manual ? null : s?.nextReminderTaskId;
    // 先按送达策略把软提醒的**实际送达时刻**算出来，再和时点提醒比早晚（v1.26）。
    // 拿没顺延的原始时刻去比，会把一个被顺延到次日上午的软提醒排在今晚的
    // 时点闹钟前面——那一晚的闹钟就被跳过了。
    final softDelivery = softAt == null ? null : windows.resolveDelivery(softAt);
    // 编排这一源只递未来的时刻，没有"送达策略"可言（静音，不挑时段）。
    final plan = plans?.nextReminder(service.now());

    DateTime? at;
    String? taskId;
    var pointFired = false;
    // 撞在同一时刻时按 编排 → 软提醒 → 时点 排：编排先占站点，到点那一刻照样会
    // `pollReminder`，任务那一条不会丢（反过来就会丢掉编排那一条）。
    if (plan != null &&
        (softDelivery == null || !plan.at.isAfter(softDelivery)) &&
        (point == null || !plan.at.isAfter(point.at))) {
      at = plan.at;
      taskId = plan.id;
      _planStation = plan;
    } else if (softDelivery != null &&
        softId != null &&
        (point == null || !point.at.isBefore(softDelivery))) {
      at = softDelivery; // 软提醒：已按送达策略顺延
      taskId = softId;
    } else if (point != null) {
      at = point.at; // 时点性提醒：原样响（决议 26）
      taskId = point.taskId;
      pointFired = true;
    }
    if (at == null || taskId == null) return;

    final station = _planStation;
    final task = station == null ? service.byId(taskId) : null;
    final channel = station != null
        ? ReminderChannel.silent
        : _channelFor(task, point: pointFired);
    final alarmOn = channel == ReminderChannel.alarm;
    // 挂闹钟时就把"到点要交付什么"定下来：安卓应用被杀时由系统闹钟
    // 自己弹通知（原生接收器照着这份草案渲染）。闹钟的正文此刻就要带上
    // "接下来"与"同时还有"——到点那一刻应用可能已经不在了。
    await alarm.scheduleNext(
      at,
      taskId,
      draft: ReminderDraft(
        taskId: taskId,
        title: station?.title ?? task?.title ?? '该做这件事了',
        body: station == null
            ? _bodyFor(task, alarm: alarmOn, at: at)
            : _planBody(station),
        channel: channel,
        fullScreen: alarmOn,
        actions: station == null ? defaultActions : const [],
      ),
    );
  }

  /// 闹钟到点。**投递只做一次**：安卓的原生接收器在回调之前就已经照着挂
  /// 闹钟时的草案弹了通知（应用被杀也照弹），所以 `delivered` 为真时这里
  /// 只记账并排下一站；再 show 一次就是同 id 替换 + 重新响铃，通知时刻被刷成
  /// "现在"——用户看到的就是"这条提醒晚了十几分钟"。
  ///
  /// 编排那一站不经过 `pollReminder`（那不是任务，没有可记账的状态）：照草案弹完就
  /// 排下一站。**同一时刻的任务提醒不受影响**——poll 照跑，撞在同一分钟时两条都到。
  Future<void> _onFired(FiredAlarm firing) async {
    final planStation = isPlanReminderId(firing.taskId) &&
            _planStation?.id == firing.taskId
        ? _planStation
        : null;
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
