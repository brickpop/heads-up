import Foundation
import Testing

@testable import HeadsUpCore

@Suite struct TerminalPlanTests {
    private let home = "/Users/me"

    private func plan(
        _ terminal: Terminal, command: String = "ssh deploy@staging", cwd: String = "~/code", shell: String = "/bin/zsh"
    ) -> TerminalPlan? {
        TerminalPlan.make(
            CommandDefinition(name: "Test", command: command, cwd: cwd),
            in: InstalledTerminal(terminal: terminal, appPath: "/Applications/\(terminal.name).app"),
            loginShell: shell, home: home)
    }

    /// The shell part of the argv: the command, after its one leading space, then the login
    /// shell keeps the window open.
    private func run(_ command: String = " ssh deploy@staging", shell: String = "/bin/zsh", login: String = "/bin/zsh")
        -> [String]
    {
        [shell, "-l", "-c", #"eval "$1"; exec "$2" -l"#, shell, command, login]
    }

    @Test func eachTerminalGetsItsOwnArgvThroughOpen() {
        let table: [(Terminal, [String])] = [
            (.ghostty, ["--working-directory=/Users/me/code", "-e"] + run()),
            (.wezterm, ["start", "--cwd=/Users/me/code", "--"] + run()),
            (.kitty, ["--directory=/Users/me/code"] + run()),
            (.alacritty, ["--working-directory=/Users/me/code", "-e"] + run()),
        ]
        for (terminal, flags) in table {
            #expect(
                plan(terminal)
                    == .process(
                        executable: "/usr/bin/open",
                        arguments: ["-na", "/Applications/\(terminal.name).app", "--args"] + flags),
                "\(terminal)")
        }
    }

    @Test func terminalAndITermCallTheirScriptWithTheValuesAsData() {
        #expect(plan(.terminal) == .script(.terminal, directory: "/Users/me/code", command: " ssh deploy@staging"))
        #expect(plan(.iterm2) == .script(.iterm2, directory: "/Users/me/code", command: " ssh deploy@staging"))
    }

    // CEO: a leading space keeps the command out of history in shells set to ignore such lines
    // (zsh HIST_IGNORE_SPACE, bash HISTCONTROL=ignorespace).
    @Test func everyTerminalGetsTheCommandAfterOneSpace() {
        for terminal in Terminal.allCases {
            switch plan(terminal) {
            case .script(_, _, let command): #expect(command == " ssh deploy@staging", "\(terminal)")
            case .process(_, let arguments): #expect(arguments.suffix(2).first == " ssh deploy@staging", "\(terminal)")
            case nil: #expect(terminal == .warp)
            }
        }
    }

    @Test func aCommandThatStartsWithASpaceIsntGivenAnother() {
        #expect(plan(.terminal, command: " ls") == .script(.terminal, directory: "/Users/me/code", command: " ls"))
        #expect(plan(.iterm2, command: "  ls") == .script(.iterm2, directory: "/Users/me/code", command: "  ls"))
        guard case .process(_, let arguments) = plan(.ghostty, command: " ls") else {
            Issue.record("expected a process")
            return
        }
        #expect(Array(arguments.suffix(7)) == run(" ls"))
    }

    @Test func theSavedCommandIsNeverChanged() throws {
        let definition = CommandDefinition(name: "Deploy", command: "ssh deploy@staging", cwd: "~/code")
        for terminal in Terminal.allCases {
            _ = TerminalPlan.make(
                definition, in: InstalledTerminal(terminal: terminal, appPath: "/Applications/x.app"),
                loginShell: "/bin/zsh", home: home)
        }
        #expect(definition.command == "ssh deploy@staging")
        let saved = try JSONDecoder().decode(CommandDefinition.self, from: JSONEncoder().encode(definition))
        #expect(saved.command == "ssh deploy@staging")
    }

    @Test func warpCantRunACommand() {
        #expect(plan(.warp) == nil)
    }

    // F14: quotes, backslashes and line breaks reach the terminal exactly as typed.
    @Test func aCommandWithQuotesBackslashesAndALineBreakIsPassedAsItIs() {
        let command = "echo \"it's \\\"here\\\"\" \\\nls -la"
        #expect(
            plan(.terminal, command: command) == .script(.terminal, directory: "/Users/me/code", command: " " + command)
        )
        guard case .process(_, let arguments) = plan(.kitty, command: command) else {
            Issue.record("expected a process")
            return
        }
        #expect(Array(arguments.suffix(7)) == run(" " + command))
    }

    // F13: the folder is never part of a shell line, and never read as an option.
    @Test func aFolderWithAQuoteOrStartingWithADash() {
        #expect(
            plan(.terminal, cwd: "/tmp/it's here")
                == .script(.terminal, directory: "/tmp/it's here", command: " ssh deploy@staging"))
        guard case .process(_, let arguments) = plan(.ghostty, cwd: "/tmp/it's here") else {
            Issue.record("expected a process")
            return
        }
        #expect(arguments.contains("--working-directory=/tmp/it's here"))
        #expect(
            plan(.terminal, cwd: "-rf")
                == .script(.terminal, directory: "/Users/me/-rf", command: " ssh deploy@staging")
        )
        guard case .process(_, let dashed) = plan(.alacritty, cwd: "-rf") else {
            Issue.record("expected a process")
            return
        }
        #expect(dashed.contains("--working-directory=/Users/me/-rf") && !dashed.contains("-rf"))
    }

    @Test func fishRunsTheCommandInZsh() {
        guard case .process(_, let arguments) = plan(.wezterm, shell: "/opt/homebrew/bin/fish") else {
            Issue.record("expected a process")
            return
        }
        // The command runs in zsh; fish is still the shell the window is left in.
        #expect(Array(arguments.suffix(7)) == run(login: "/opt/homebrew/bin/fish"))
        guard case .process(_, let bash) = plan(.wezterm, shell: "/bin/bash") else { return }
        #expect(Array(bash.suffix(7)) == run(shell: "/bin/bash", login: "/bin/bash"))
    }

    @Test func terminalsAreFoundByBundleID() {
        for terminal in Terminal.allCases {
            #expect(Terminal(bundleID: terminal.bundleID) == terminal)
        }
        #expect(Terminal(bundleID: "com.example.nope") == nil)
    }
}

/// The fixed scripts in Resources (F14): one handler, two parameters, nothing filled in.
@Suite struct TerminalScriptTests {
    private func source(_ script: TerminalScript) throws -> String {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        return try String(
            contentsOf: resources.appendingPathComponent("\(script.rawValue).applescript"), encoding: .utf8)
    }

    @Test func eachScriptHasTheOneHandlerAndTargetsItsOwnApp() throws {
        for (script, bundleID) in [(TerminalScript.terminal, "com.apple.Terminal"), (.iterm2, "com.googlecode.iterm2")]
        {
            let text = try source(script)
            #expect(text.contains("on \(TerminalScript.handler)(theDir, theCommand)"))
            #expect(text.contains("tell application id \"\(bundleID)\""))
            #expect(text.contains("quoted form of theDir"))
            // The typed line starts with a space, so the shell can keep it out of history.
            #expect(text.contains(#"" cd " & quoted form of theDir"#))
            // No other app is named, and nothing is left to fill in.
            #expect(text.components(separatedBy: "tell application").count == 2)
            #expect(!text.contains("%@") && !text.contains("{{") && !text.contains("$("))
        }
        #expect(try source(.iterm2).contains("create window with default profile"))
        #expect(try source(.iterm2).contains("write text"))
    }
}

@Suite struct CommandDefinitionTests {
    @Test func theRulesOfACommand() {
        #expect(CommandDefinition(name: "SSH", command: "ssh host").problems.isEmpty)
        #expect(CommandDefinition(name: " ", command: "x").problems[.name] == "Enter a name.")
        #expect(CommandDefinition(name: String(repeating: "a", count: 65), command: "x").problems[.name] != nil)
        #expect(CommandDefinition(name: "a", command: " ").problems[.command] == "Enter a command to run.")
        #expect(CommandDefinition(name: "a", command: "ls\0rm").problems[.command] != nil)
        #expect(CommandDefinition(name: "a", command: "ls", cwd: "/tmp\0x").problems[.cwd] != nil)
    }
}

/// The shell part of the `open` argv, run for real with /bin/sh: the command runs exactly as
/// typed, then the login shell takes over (here an echo that stands in for it).
@Suite struct TerminalShellLineTests {
    private func output(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func quotesDollarsAndSemicolonsRunAsTyped() throws {
        let command = #"printf '%s|' "it's" 'a;b' "$((1 + 2))" \$HOME; echo"#
        guard
            case .process(_, let arguments) = TerminalPlan.make(
                CommandDefinition(name: "T", command: command),
                in: InstalledTerminal(terminal: .kitty, appPath: "/Applications/kitty.app"), loginShell: "/bin/echo",
                home: "/tmp")
        else {
            Issue.record("expected a process")
            return
        }
        // /bin/echo isn't a shell HeadsUp runs commands with, so zsh would run it; sh stands in.
        var line = Array(arguments.suffix(7))
        line[0] = "/bin/sh"
        line[4] = "/bin/sh"
        #expect(try output(line) == "it's|a;b|3|$HOME|\n-l\n")
    }
}
