import Foundation

/// How a service is started (ADR-001 §7.2, F13): through the user's login shell, so `PATH` is
/// the one their Terminal has, with the folder set by the spawn itself, never by a `cd` in a
/// shell line. Nothing is quoted or put together into a command line by HeadsUp.
public struct SpawnPlan: Equatable, Sendable {
    /// The shell to run.
    public let executable: String
    /// The whole argv: `[shell, "-l", "-c", command]`.
    public let arguments: [String]
    /// The folder, with `~` expanded; set with `posix_spawn_file_actions_addchdir_np`.
    public let directory: String
    /// `KEY=value` entries: HeadsUp's environment with the service's own on top.
    public let environment: [String]
    /// Set when the user's shell isn't one HeadsUp runs commands with, and zsh is used instead.
    public let shellFallback: String?

    /// Shells that take `-l -c command` the POSIX way. Others (fish, nushell…) quote and run
    /// commands differently, so zsh runs the command instead.
    public static let supportedShells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh"]
    public static let fallbackShell = "/bin/zsh"

    public init(
        definition: ServiceDefinition, loginShell: String, home: String, baseEnvironment: [String: String]
    ) {
        let shellName = (loginShell as NSString).lastPathComponent
        let shell: String
        if Self.supportedShells.contains(shellName) && loginShell.hasPrefix("/") {
            shell = loginShell
            shellFallback = nil
        } else {
            shell = Self.fallbackShell
            shellFallback = shellName.isEmpty ? "unknown" : shellName
        }
        executable = shell
        arguments = [shell, "-l", "-c", definition.command]
        directory = Self.expand(definition.cwd, home: home)

        var environment = baseEnvironment
        for variable in definition.env {
            environment[variable.key] = variable.value
        }
        self.environment = environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// `~` and `~/…` become the home folder; an empty folder is home; a relative path is taken
    /// from home. Anything else is used as it is: no shell ever reads it.
    static func expand(_ path: String, home: String) -> String {
        if path.isEmpty || path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        if path.hasPrefix("/") { return path }
        return home + "/" + path
    }
}
