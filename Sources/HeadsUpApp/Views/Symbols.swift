import HeadsUpCore

/// The SF Symbol for each icon the core names. Symbol names live only here.
extension Glyph {
    var symbolName: String {
        switch self {
        case .chat: "bubble.left"
        case .timer: "timer"
        case .cup: "cup.and.saucer"
        case .servers: "server.rack"
        case .terminal: "terminal"
        case .sliders: "slider.horizontal.3"
        case .sparkle: "sparkle"
        case .stop: "stop.circle"
        case .droplet: "drop"
        case .plus: "plus"
        case .cpu: "cpu"
        case .server: "server.rack"
        case .pin: "pin"
        case .pause: "pause.circle"
        case .folder: "folder"
        case .eye: "eye"
        case .activity: "figure.arms.open"
        case .people: "person.2"
        case .utensils: "fork.knife"
        case .dot: "circle.fill"
        case .play: "play.fill"
        case .calendar: "calendar"
        case .check: "checklist"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

/// Symbols the views show that aren't a core glyph.
enum Symbols {
    /// The accent check in front of a toast.
    static let toastCheck = "checkmark.circle.fill"
    /// The warning icon on a notice bar, in orange.
    static let warning = "exclamationmark.triangle.fill"
    /// The ghost × that dismisses a notice.
    static let close = "xmark"
    /// The bell on the Snooze group.
    static let snooze = "bell"
    /// The break prompt's Length group: an hourglass, since the timer is the Focus tab's icon.
    static let breakLength = "hourglass"
    /// The Logs toggle on a service row.
    static let logs = "list.bullet"
    /// The status dot of a failed service: red with a small ×.
    static let failedDot = "xmark.circle.fill"
    /// The badge on the Caffeine chip while paused on battery.
    static let pauseBadge = "pause.circle.fill"
    /// The back button of a Settings form: ‹ Services.
    static let back = "chevron.left"
    /// The chevron at the end of a row that opens a form.
    static let disclosure = "chevron.right"
    /// Removes a row, such as an environment variable.
    static let minus = "minus"
    /// The terminal pill on a command row: it opens in another app.
    static let externalLink = "arrow.up.right.square"
    /// The chevron on the model chip.
    static let chevronDown = "chevron.down"
    /// The check on the active model.
    static let check = "checkmark"
    /// The default-endpoint radio, off and on.
    static let radioOff = "circle"
    static let radioOn = "largecircle.fill.circle"
    /// The Copy button on a code block.
    static let copy = "doc.on.doc"
    /// The info icon on a problem row that is not a failure (the step limit).
    static let info = "info.circle"
    /// Task-list markers, unchecked and checked.
    static let taskOff = "square"
    static let taskOn = "checkmark.square"
    /// The header's Attach image button.
    static let paperclip = "paperclip"
    /// A thumbnail with no preview, and the drop zone.
    static let photo = "photo"
    /// Pinned · N in the chat toolbar.
    static let list = "list.bullet"
    /// A service that keeps the Mac awake while it runs, after its meta.
    static let keepsAwake = "cup.and.saucer"
    /// A service that restarts if it stops, after its meta.
    static let restarts = "arrow.clockwise"
    /// A numbered step in the welcome: 1 in a circle.
    static func step(_ number: Int) -> String { "\(number).circle" }
}
