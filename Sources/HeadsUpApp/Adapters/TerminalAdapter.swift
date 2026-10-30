import AppKit
import Carbon.OpenScripting
import CoreServices
import HeadsUpCore

/// Finds terminal apps by bundle id and opens commands in them (ADR-001 §7.3).
///
/// - Terminal and iTerm2: the fixed script from the bundle (`Terminal.applescript` or
///   `iTerm.applescript`) is compiled once, then its `run_in_terminal` handler is called with an
///   Apple event whose parameters are the folder and the command (F14). Only the chosen
///   terminal's script is ever compiled or run, so macOS asks Automation consent for that one.
///   That consent is asked before the run, off the main thread (`askAutomationConsent`).
///   NSAppleScript isn't thread-safe, so this runs on the main actor.
/// - The others: `/usr/bin/open` with the plan's argv, off the main actor, never through a shell.
@MainActor
final class SystemTerminalLauncher: TerminalLauncher {
    private var scripts: [TerminalScript: NSAppleScript] = [:]
    private let prompts: PermissionPrompts

    init(prompts: PermissionPrompts) {
        self.prompts = prompts
    }

    func installed() -> [InstalledTerminal] {
        Terminal.allCases.compactMap { terminal in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID).map {
                InstalledTerminal(terminal: terminal, appPath: $0.path)
            }
        }
    }

    func run(_ plan: TerminalPlan) async -> TerminalRunResult {
        switch plan {
        case .script(let script, let directory, let command):
            let wrap = await askAutomationConsent(for: script)
            return runScript(script, parameters: [directory, command], wrappedInPrompt: wrap)
        case .process(let executable, let arguments):
            return await Task.detached { Self.runProcess(executable, arguments) }.value
        }
    }

    // MARK: Automation consent

    /// macOS asks the user once, the first time HeadsUp drives a terminal. That question is asked
    /// here, before the run and off the main thread, so the HUD keeps ticking while the prompt is
    /// up, and the HUD is lowered (`prompts`) only when macOS will really ask. The script run
    /// then never prompts. Returns true when that couldn't be settled: the terminal isn't running
    /// yet (-600), so the run, which launches it, may still ask, and is wrapped as before.
    /// Two runs close together can both wait here for the same answer. That is harmless: the
    /// `prompts` holds nest, and macOS shows one prompt.
    private func askAutomationConsent(for script: TerminalScript) async -> Bool {
        let bundleID = Self.terminal(for: script).bundleID
        let status = await Task.detached { Self.automationConsent(bundleID, askingUser: false) }.value
        switch Int(status) {
        case errAEEventWouldRequireUserConsent:  // -1744: macOS will ask
            prompts.begin()
            _ = await Task.detached { Self.automationConsent(bundleID, askingUser: true) }.value
            prompts.end()
            return false
        case procNotFound:  // -600
            return true
        default:  // allowed, or refused before: no prompt either way
            return false
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` for any event to the app with `bundleID`. With
    /// `askingUser`, it shows the Automation prompt if macOS hasn't asked yet, and waits for it.
    private nonisolated static func automationConsent(_ bundleID: String, askingUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        // `aeDesc` points into `target`: keep it alive for the whole call.
        return withExtendedLifetime(target) { () -> OSStatus in
            guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(
                desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askingUser)
        }
    }

    private static func terminal(for script: TerminalScript) -> Terminal {
        switch script {
        case .terminal: .terminal
        case .iterm2: .iterm2
        }
    }

    // MARK: AppleScript

    private func runScript(_ script: TerminalScript, parameters: [String], wrappedInPrompt: Bool) -> TerminalRunResult {
        let compiled: NSAppleScript
        do {
            compiled = try load(script)
        } catch {
            return error.result
        }
        let list = NSAppleEventDescriptor.list()
        for (index, parameter) in parameters.enumerated() {
            list.insert(NSAppleEventDescriptor(string: parameter), at: index + 1)
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        // AppleScript stores handler names in lower case.
        event.setDescriptor(
            NSAppleEventDescriptor(string: TerminalScript.handler.lowercased()),
            forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        // Only when macOS couldn't tell beforehand whether it would ask (askAutomationConsent).
        if wrappedInPrompt { prompts.begin() }
        compiled.executeAppleEvent(event, error: &error)
        if wrappedInPrompt { prompts.end() }
        return error.map(Self.result) ?? .opened
    }

    /// Why a script couldn't be loaded, as the result of the run.
    private struct LoadFailure: Error {
        let result: TerminalRunResult
    }

    /// The script, compiled the first time it is needed.
    private func load(_ script: TerminalScript) throws(LoadFailure) -> NSAppleScript {
        if let compiled = scripts[script] { return compiled }
        guard let url = Bundle.main.url(forResource: script.rawValue, withExtension: "applescript"),
            let source = NSAppleScript(contentsOf: url, error: nil)
        else { throw LoadFailure(result: .failed("\(script.rawValue).applescript is missing from the app")) }
        var error: NSDictionary?
        guard source.compileAndReturnError(&error) else {
            throw LoadFailure(result: error.map(Self.result) ?? .failed("the script didn't compile"))
        }
        scripts[script] = source
        return source
    }

    private static func result(_ error: NSDictionary) -> TerminalRunResult {
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        switch code {
        // errAEEventNotPermitted, errAEEventWouldRequireUserConsent
        case -1743, -1744: return .notAllowed
        // procNotFound, and the app can't be found to launch
        case -600, -10814: return .notInstalled
        default:
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
            return .failed(message)
        }
    }

    // MARK: open

    nonisolated private static func runProcess(_ executable: String, _ arguments: [String]) -> TerminalRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .opened }
        let firstLine = String(decoding: output, as: UTF8.self).split(separator: "\n").first.map(String.init)
        return .failed(firstLine ?? "open exited with code \(process.terminationStatus)")
    }
}
