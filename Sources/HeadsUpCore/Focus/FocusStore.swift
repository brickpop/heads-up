import Foundation
import Observation

/// The Focus timer (ADR-001 §4.2; Focus spec): the state machine, today's stats, the
/// notifications at each end date, auto-open, snooze, and Settings → Focus.
///
/// It arms one wake-up, for the next deadline, and nothing while idle. Its notification is
/// scheduled with the system at the same date, so it arrives even if HeadsUp is asleep.
@MainActor
@Observable
public final class FocusStore {
    /// The id of the one Focus notification, pending or shown.
    static let notificationID = "focus.timer"
    /// How long the HUD stays after Snooze, so the user sees the toast.
    static let hideAfterSnooze: TimeInterval = 0.6
    /// How long the HUD stays after a focus or a break starts from it (CEO, 2026-10-29).
    static let startHideDelay: TimeInterval = 1.5

    public private(set) var machine: FocusMachine
    /// The break activity picked in the break prompt.
    public private(set) var breakActivity: BreakOption.ID
    /// The break length picked in the break prompt, in minutes.
    public private(set) var breakLength: Int
    private var todayCounts: (day: String, counts: FocusDay)
    /// The length of the focus that brought the break prompt, for its notification's title;
    /// nil after Take a break now.
    private(set) var promptMinutes: Int?
    /// The length picked on the back prompt, while it shows or is snoozed; nil before a pick.
    private var backPromptPick: Int?
    /// Counts the card moves made with ⌥← ⌥→ from the prompt field. The view announces the
    /// newly selected card each time it changes, as it does for the arrow keys in the cards.
    public private(set) var cardMoves = 0

    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private let history: FocusHistory
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private weak var navigator: Navigator?
    @ObservationIgnored private weak var toaster: Toaster?
    @ObservationIgnored private var wakeUp: ScheduledWork?
    @ObservationIgnored private var pendingHide: ScheduledWork?
    /// Whether VoiceOver is on. The shell sets it (NSWorkspace); while it is on, a start doesn't
    /// hide the HUD, which stays until Esc (Yuki, focus-loop-keys).
    @ObservationIgnored public var isVoiceOverOn: @MainActor () -> Bool = { false }

    public init(
        clock: Clock, scheduler: Scheduler, settings: SettingsStore, history: FocusHistory, notifier: Notifier,
        navigator: Navigator, toaster: Toaster, secondsPerMinute: TimeInterval = 60
    ) {
        machine = FocusMachine(secondsPerMinute: secondsPerMinute)
        self.clock = clock
        self.scheduler = scheduler
        self.settings = settings
        self.history = history
        self.notifier = notifier
        self.navigator = navigator
        self.toaster = toaster
        let options = settings.settings.focus.breakOptions
        let initial = options.first { $0.id == BreakOption.initialID } ?? options[0]
        breakActivity = initial.id
        breakLength = initial.length
        let today = FocusDayFormat.string(clock.now)
        todayCounts = (today, history.day(today))
    }

    // MARK: State for the views

    public var phase: FocusPhase { machine.phase }

    /// The focus length, the same value as Settings → Focus → Focus length.
    public var focusLength: Int { settings.settings.focus.focusLength }

    /// The focus the back prompt starts: the one picked there, else the last focus's length,
    /// else Settings' focus length. Picking it doesn't change Settings.
    public var nextFocusLength: Int { backPromptPick ?? machine.nextFocusMinutes(standard: focusLength) }

    /// The back prompt's length cards: the presets, and the last focus's length in its place
    /// among them if it was typed (`/start 35`).
    public var backPromptLengths: [Int] {
        var lengths = FocusSettings.focusLengths
        if let last = machine.lastFocusMinutes, !lengths.contains(last) {
            lengths.append(last)
            lengths.sort()
        }
        return lengths
    }

    /// Today's completed sessions; zero again after local midnight.
    public var today: FocusDay {
        let day = FocusDayFormat.string(clock.now)
        return day == todayCounts.day ? todayCounts.counts : FocusDay()
    }

    /// The selected break activity, or the first option if it was removed.
    public var activity: BreakOption {
        let options = settings.settings.focus.breakOptions
        return options.first { $0.id == breakActivity } ?? options[0]
    }

    /// What the menu bar, the menu and the tab dot need.
    public var snapshot: FocusSnapshot {
        switch machine.phase {
        case .idle: .idle(nextLength: focusLength)
        case .focus(let run): Self.snapshot(of: run, kind: .focus)
        case .rest(let run, _): Self.snapshot(of: run, kind: .rest)
        case .prompt(.breakPrompt): .prompt(.breakDue)
        case .prompt(.backPrompt): .prompt(.breakOver)
        case .snoozed(let until, _): .snoozed(until: until)
        }
    }

    /// The footer pill at `now`: "Focus 18:42", "Break 3:10" or "Snoozed 4:12", or nil.
    public func pill(at now: Date) -> String? {
        switch machine.phase {
        case .focus(let run): Strings.Focus.pillFocus(Format.clock(run.timeLeft(at: now)))
        case .rest(let run, _): Strings.Focus.pillBreak(Format.clock(run.timeLeft(at: now)))
        case .snoozed(let until, _): Strings.Focus.pillSnoozed(Format.clock(until.timeIntervalSince(now)))
        case .idle, .prompt: nil
        }
    }

    private static func snapshot(of run: FocusRun, kind: FocusSnapshot.Kind) -> FocusSnapshot {
        if let endsAt = run.endsAt { return .running(kind, endsAt: endsAt) }
        return .paused(kind, left: run.pausedLeft ?? 0)
    }

    // MARK: The user's moves

    /// Start focus, with the selected length, from the HUD: it hides after `startHideDelay`.
    /// Idle selects Settings' focus length, the back prompt its own.
    public func start() {
        start(minutes: phase == .prompt(.backPrompt) ? nextFocusLength : focusLength)
        hideAfterStart()
    }

    /// Start focus with `minutes`, from any phase. Toasts, and asks for notification permission
    /// the first time (UX part 2: "when the first focus starts, not at launch"). Returns when it
    /// ends.
    @discardableResult
    public func start(minutes: Int) -> Date {
        notifier.requestAuthorization()
        change { $0.start(minutes: minutes, now: clock.now) }
        toaster?.toast(Strings.Focus.focusStarted(minutes))
        return endDate
    }

    public func pause() { change { $0.pause(now: clock.now) } }
    public func resume() { change { $0.resume(now: clock.now) } }
    public func stop() { change { $0.stop() } }
    public func endBreak() { change { $0.endBreak() } }
    /// Done, from either prompt: the loop ends, back to idle.
    public func doneForNow() { change { $0.doneForNow() } }
    public func showNow() { change { $0.showNow() } }

    /// A break of `minutes` at once, with the selected activity, from any phase: typed
    /// `/break 7`, or the focus.timer tool. Toasts like Start break. Returns when it ends.
    @discardableResult
    public func takeBreak(minutes: Int) -> Date {
        notifier.requestAuthorization()
        promptMinutes = nil
        let activity = activity.id
        change { $0.takeBreak(minutes: minutes, activity: activity, now: clock.now) }
        toaster?.toast(Strings.Focus.breakStarted(minutes))
        return endDate
    }

    /// When the running focus or break ends; now when nothing runs.
    private var endDate: Date {
        switch machine.phase {
        case .focus(let run), .rest(let run, _): run.endsAt ?? clock.now
        default: clock.now
        }
    }

    public func takeBreakNow() {
        promptMinutes = nil
        change { $0.takeBreakNow() }
    }

    /// Start break, from the HUD's break prompt: the HUD hides after `startHideDelay`.
    public func startBreak() {
        guard beginBreak() else { return }
        hideAfterStart()
    }

    /// Starts the break the prompt has picked, if it shows. False when it doesn't.
    private func beginBreak() -> Bool {
        guard case .prompt(.breakPrompt) = machine.phase else { return false }
        let minutes = breakLength
        change { $0.startBreak(activity: activity.id, minutes: minutes, now: clock.now) }
        toaster?.toast(Strings.Focus.breakStarted(minutes))
        return true
    }

    /// Snooze from the HUD, for `minutes` (2, 5 or 10) or Settings' snooze length: toasts, then
    /// hides the HUD after 600 ms.
    public func snooze(minutes: Int? = nil) {
        guard case .prompt = machine.phase else { return }
        let minutes = minutes ?? settings.settings.focus.snoozeMinutes
        guard FocusSettings.snoozeLengths.contains(minutes) else { return }
        change { $0.snooze(minutes: minutes, now: clock.now) }
        toaster?.toast(Strings.Focus.snoozed(minutes))
        hideSoon(after: Self.hideAfterSnooze)
    }

    /// Hides the open HUD after `delay`, the toast having shown meanwhile, unless the user does
    /// something in the HUD first (`cancelHideSoon()`). For moves made in the HUD only: a start
    /// from a notification or the chat's tool never hides it.
    func hideSoon(after delay: TimeInterval) {
        cancelHideSoon()
        guard navigator?.isOpen == true else { return }
        pendingHide = scheduler.schedule(at: clock.now.addingTimeInterval(delay)) { [weak self] in
            self?.pendingHide = nil
            self?.navigator?.close()
        }
    }

    /// A focus or a break started from the HUD: it hides after `startHideDelay`, except with VoiceOver on.
    func hideAfterStart() {
        if isVoiceOverOn() {
            cancelHideSoon()
            return
        }
        hideSoon(after: Self.startHideDelay)
    }

    /// The user did something in the HUD (typed, switched tab, used a Focus control): it stays
    /// open.
    public func cancelHideSoon() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    /// Picks a break activity; the break length becomes its default.
    public func selectActivity(_ id: BreakOption.ID) {
        guard let option = settings.settings.focus.breakOptions.first(where: { $0.id == id }) else { return }
        cancelHideSoon()
        breakActivity = option.id
        breakLength = option.length
    }

    public func setBreakLength(_ minutes: Int) {
        guard FocusSettings.breakLengths.contains(minutes) else { return }
        cancelHideSoon()
        breakLength = minutes
    }

    /// Picks the focus length on the back prompt, one of `backPromptLengths`.
    public func setNextFocusLength(_ minutes: Int) {
        guard phase == .prompt(.backPrompt), backPromptLengths.contains(minutes) else { return }
        cancelHideSoon()
        backPromptPick = minutes
    }

    /// Whether the Focus tab shows a prompt, where esc snoozes.
    public var showsPrompt: Bool {
        if case .prompt = machine.phase { return true }
        return false
    }

    // MARK: Keys

    /// ⌥← (-1) or ⌥→ (+1): the previous or next card, stopping at the ends. Idle and the back
    /// prompt move among the focus lengths, the break prompt among the break options. Returns
    /// false where there are no cards, so the key goes on to the prompt field.
    public func moveCardSelection(by delta: Int) -> Bool {
        switch machine.phase {
        case .idle:
            let lengths = FocusSettings.focusLengths
            guard let next = Self.step(lengths.firstIndex(of: focusLength), by: delta, count: lengths.count) else {
                return true
            }
            setFocusLength(lengths[next])
        case .prompt(.backPrompt):
            let lengths = backPromptLengths
            guard let next = Self.step(lengths.firstIndex(of: nextFocusLength), by: delta, count: lengths.count)
            else { return true }
            setNextFocusLength(lengths[next])
        case .prompt(.breakPrompt):
            let options = settings.settings.focus.breakOptions
            let current = options.firstIndex { $0.id == activity.id }
            guard let next = Self.step(current, by: delta, count: options.count) else { return true }
            selectActivity(options[next].id)
        default:
            return false
        }
        // After the selection has changed: the view announces the card selected when this
        // changes, so counting first would read out the old one.
        cardMoves += 1
        return true
    }

    /// The card after `current` by `delta`, or nil at an end.
    private static func step(_ current: Int?, by delta: Int, count: Int) -> Int? {
        let next = min(max((current ?? 0) + delta, 0), count - 1)
        return next == current ? nil : next
    }

    /// Whether the Focus tab shows a group of cards that ⌥← ⌥→ move through: the focus lengths
    /// when idle and in the back prompt, the break options in the break prompt.
    public var showsCards: Bool {
        switch machine.phase {
        case .idle, .prompt: true
        default: false
        }
    }

    /// ⌘↩: the primary button of what the Focus tab shows. Idle and the back prompt start a
    /// focus, the break prompt starts the break, snoozed shows the prompt now. A running focus
    /// or break has none, and returns false.
    public func runPrimaryAction() -> Bool {
        switch machine.phase {
        case .idle, .prompt(.backPrompt): start()
        case .prompt(.breakPrompt): startBreak()
        case .snoozed: showNow()
        case .focus, .rest: return false
        }
        return true
    }

    // MARK: Settings → Focus

    public func setFocusLength(_ minutes: Int) {
        guard FocusSettings.focusLengths.contains(minutes) else { return }
        settings.update { $0.focus.focusLength = minutes }
    }

    public func setSnoozeMinutes(_ minutes: Int) {
        guard FocusSettings.snoozeLengths.contains(minutes) else { return }
        settings.update { $0.focus.snoozeMinutes = minutes }
    }

    public func setOpenHudOnEnd(_ on: Bool) {
        settings.update { $0.focus.openHudOnEnd = on }
    }

    /// The notification for a running break changes with this setting, so it is rescheduled.
    public func setAutoStartNextFocus(_ on: Bool) {
        settings.update { $0.focus.autoStartNextFocus = on }
        updateNotification()
    }

    /// Add option: an empty label adds nothing. New options get the dot and go last.
    public func addBreakOption(label: String, minutes: Int = FocusSettings.newOptionLength) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let option = BreakOption(id: "custom-\(UUID().uuidString)", label: trimmed, icon: .dot, length: minutes)
        settings.update { $0.focus.breakOptions.append(option) }
    }

    /// Removes an option, except the last one: there is always one to pick.
    public func removeBreakOption(_ id: BreakOption.ID) {
        guard settings.settings.focus.breakOptions.count > 1 else { return }
        settings.update { $0.focus.breakOptions.removeAll { $0.id == id } }
        if breakActivity == id { selectActivity(activity.id) }
    }

    /// The length pill on an option: 2 → 5 → 10 → 20 → 50 → 2.
    public func cycleBreakOptionLength(_ id: BreakOption.ID) {
        settings.update { settings in
            guard let index = settings.focus.breakOptions.firstIndex(where: { $0.id == id }) else { return }
            let lengths = FocusSettings.breakLengths
            let current = lengths.firstIndex(of: settings.focus.breakOptions[index].length) ?? 0
            settings.focus.breakOptions[index].length = lengths[(current + 1) % lengths.count]
        }
    }

    // MARK: Time

    /// After the Mac wakes or its clock changes: anything that ended meanwhile happens now.
    public func clockJumped() {
        advance()
    }

    /// Moves the machine on if a deadline has passed, and acts on what happened.
    func advance() {
        let before = machine.phase
        // The same length the back prompt would start: the last focus's.
        let autoStart =
            settings.settings.focus.autoStartNextFocus ? machine.nextFocusMinutes(standard: focusLength) : nil
        guard let event = machine.advance(now: clock.now, autoStartMinutes: autoStart) else {
            armWakeUp()
            return
        }
        switch event {
        case .focusCompleted(let minutes, let endedAt):
            let day = FocusDayFormat.string(endedAt)
            history.recordSession(minutes: minutes, day: day)
            todayCounts = (day, history.day(day))
            promptMinutes = minutes
            autoOpen(Strings.Focus.focusDoneAnnouncement)
        case .breakCompleted(let autoStarted?):
            toaster?.toast(Strings.Focus.focusStarted(autoStarted))
        case .breakCompleted(nil):
            autoOpen(Strings.Focus.breakOverAnnouncement)
        case .snoozeEnded(.breakPrompt):
            autoOpen(Strings.Focus.snoozeOverBreakAnnouncement)
        case .snoozeEnded(.backPrompt):
            autoOpen(Strings.Focus.breakOverAnnouncement)
        }
        phaseChanged(from: before)
    }

    /// Brings the prompt to the user, if the setting is on: the HUD decides how, by its state.
    private func autoOpen(_ announcement: String) {
        guard settings.settings.focus.openHudOnEnd else { return }
        navigator?.autoOpen(tab: .focus, announcement: announcement)
    }

    /// Applies a move, then brings the wake-up and the notification up to date.
    private func change(_ move: (inout FocusMachine) -> Void) {
        cancelHideSoon()
        let before = machine.phase
        move(&machine)
        phaseChanged(from: before)
    }

    private func phaseChanged(from before: FocusPhase) {
        // A pick on the back prompt lasts while it shows or is snoozed; the next one starts from
        // the last focus again.
        switch machine.phase {
        case .prompt(.backPrompt), .snoozed(_, .backPrompt): break
        default: backPromptPick = nil
        }
        armWakeUp()
        updateNotification()
        // A prompt's notification stays in Notification Center until the prompt is answered
        // or gives way; then it is removed.
        if case .prompt(let prompt) = before, machine.phase != .prompt(prompt) {
            notifier.removeDelivered(id: Self.notificationID)
        }
    }

    private func armWakeUp() {
        wakeUp?.cancel()
        wakeUp = machine.nextDeadline.map { deadline in
            scheduler.schedule(at: deadline) { [weak self] in self?.advance() }
        }
    }

    /// The one pending Focus notification: at the end of the running focus or break, or at the
    /// end of a snooze with the copy of the prompt it brings back. Nothing while paused or idle.
    /// A notification already shown is left alone.
    private func updateNotification() {
        notifier.cancelPending(id: Self.notificationID)
        switch machine.phase {
        case .focus(let run):
            guard let endsAt = run.endsAt else { return }
            schedule(.focusEnd, title: Strings.Notifications.focusDoneTitle(run.minutes), at: endsAt)
        case .rest(let run, _):
            guard let endsAt = run.endsAt else { return }
            if settings.settings.focus.autoStartNextFocus {
                schedule(
                    .breakAutostart, title: Strings.Notifications.breakOverTitle,
                    body: Strings.Notifications.focusStartedBody(machine.nextFocusMinutes(standard: focusLength)),
                    at: endsAt)
            } else {
                schedule(.breakEnd, title: Strings.Notifications.breakOverTitle, at: endsAt)
            }
        case .snoozed(let until, .breakPrompt):
            schedule(
                .focusEnd, title: Strings.Notifications.snoozeOverBreakTitle,
                body: Strings.Notifications.snoozeOverBreakBody(focusMinutes: promptMinutes), at: until)
        case .snoozed(let until, .backPrompt):
            schedule(
                .breakEnd, title: Strings.Notifications.breakOverTitle, body: Strings.Notifications.snoozeOverBackBody,
                at: until)
        case .idle, .prompt:
            break
        }
    }

    private func schedule(_ category: NotificationCategory, title: String, body: String? = nil, at date: Date) {
        let body =
            body
            ?? (category == .focusEnd ? Strings.Notifications.focusDoneBody : Strings.Notifications.breakOverBody)
        notifier.schedule(
            NotificationRequest(id: Self.notificationID, category: category, title: title, body: body, date: date))
    }

    // MARK: Notifications

    /// An answer from Notification Center. A button that no longer fits the timer's state
    /// (an old notification) does nothing; a click on the body opens the HUD on Focus.
    public func handleNotification(_ category: NotificationCategory, action: NotificationAction?) {
        advance()  // the end may have passed while HeadsUp slept
        guard let action else {
            navigator?.open(tab: .focus, makeKey: true)
            return
        }
        guard category.actions.contains(action) else { return }
        switch (action, machine.phase) {
        // Answers from Notification Center don't hide the HUD: it may be open for something else.
        case (.startBreak, .prompt(.breakPrompt)):
            _ = beginBreak()
        case (.startFocus, .prompt(.backPrompt)):
            start(minutes: nextFocusLength)
        case (.done, .prompt):
            doneForNow()
        case (.snooze, .prompt):
            let minutes = settings.settings.focus.snoozeMinutes
            change { $0.snooze(minutes: minutes, now: clock.now) }
        case (.stop, .focus):
            stop()
        default:
            break
        }
    }
}

extension FocusStore: FocusControlling {}
