import Foundation

/// The terminal apps Commands can open in (ADR-001 §7.3), found by bundle id.
public enum Terminal: String, CaseIterable, Sendable {
    case terminal, iterm2, ghostty, warp, wezterm, kitty, alacritty

    public var name: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .wezterm: "WezTerm"
        case .kitty: "Kitty"
        case .alacritty: "Alacritty"
        }
    }

    public var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        case .wezterm: "com.github.wez.wezterm"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        }
    }

    public init?(bundleID: String) {
        guard let terminal = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = terminal
    }
}

/// A terminal app found on this Mac.
public struct InstalledTerminal: Equatable, Sendable {
    public let terminal: Terminal
    /// Where the app is, e.g. /Applications/Ghostty.app.
    public let appPath: String

    public init(terminal: Terminal, appPath: String) {
        self.terminal = terminal
        self.appPath = appPath
    }
}

/// The fixed AppleScript files in Resources, each with the handler
/// `run_in_terminal(theDir, theCommand)` (F14).
public enum TerminalScript: String, Sendable {
    case terminal = "Terminal"
    case iterm2 = "iTerm"

    /// The handler the launcher calls. The folder and the command are its parameters: data,
    /// never part of the script's source.
    public static let handler = "run_in_terminal"
}

/// How a command is opened in a terminal (ADR-001 §7.3, F13, F14). Nothing is quoted or put
/// together into a line by HeadsUp: the command reaches a shell only as one argument.
public enum TerminalPlan: Equatable, Sendable {
    /// Terminal and iTerm2: call the script's handler with these two parameters.
    case script(TerminalScript, directory: String, command: String)
    /// The others: run `executable` with this argv, never through a shell.
    case process(executable: String, arguments: [String])

    static let open = "/usr/bin/open"
    /// Runs the command ($1), then replaces itself with the login shell ($2).
    static let thenStayOpen = #"eval "$1"; exec "$2" -l"#

    /// The plan for running `command` in `installed`, or nil for a terminal that can't run a
    /// command (Warp). The folder has `~` expanded and is always absolute, so it can't be read
    /// as an option.
    public static func make(
        _ command: CommandDefinition, in installed: InstalledTerminal, loginShell: String, home: String
    ) -> TerminalPlan? {
        let directory = SpawnPlan.expand(command.cwd, home: home)
        let shell = SpawnPlan.shell(for: loginShell).shell
        // The command runs in a POSIX shell, then the user's own login shell (even fish) takes
        // over, so the window stays open as in Terminal. The command and that shell are the
        // script's arguments $1 and $2: data, never part of the line.
        let interactive = loginShell.hasPrefix("/") ? loginShell : shell
        let run = [shell, "-l", "-c", Self.thenStayOpen, shell, command.command, interactive]
        let flags: [String]
        switch installed.terminal {
        case .terminal:
            return .script(.terminal, directory: directory, command: command.command)
        case .iterm2:
            return .script(.iterm2, directory: directory, command: command.command)
        case .warp:
            return nil
        case .ghostty:
            flags = ["--working-directory=\(directory)", "-e"] + run
        case .wezterm:
            flags = ["start", "--cwd=\(directory)", "--"] + run
        case .kitty:
            flags = ["--directory=\(directory)"] + run
        case .alacritty:
            flags = ["--working-directory=\(directory)", "-e"] + run
        }
        return .process(executable: open, arguments: ["-na", installed.appPath, "--args"] + flags)
    }
}
