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
    /// The bell on Snooze buttons.
    static let snooze = "bell"
    /// A numbered step in the welcome: 1 in a circle.
    static func step(_ number: Int) -> String { "\(number).circle" }
}
