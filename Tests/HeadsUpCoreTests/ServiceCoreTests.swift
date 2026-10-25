import Foundation
import Testing

@testable import HeadsUpCore

@Suite struct SpawnPlanTests {
    private let home = "/Users/me"

    private func plan(cwd: String = "~", command: String = "npm run dev", shell: String = "/bin/zsh") -> SpawnPlan {
        SpawnPlan(
            definition: ServiceDefinition(name: "Web", command: command, cwd: cwd), loginShell: shell, home: home,
            baseEnvironment: ["PATH": "/usr/bin", "HOME": home])
    }

    @Test func theCommandRunsThroughTheLoginShellUntouched() {
        let command = #"echo "it's $HOME" && npm run dev -- --port 3000"#
        let plan = plan(command: command)
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.arguments == ["/bin/zsh", "-l", "-c", command])
    }

    // F13: the folder is never part of a shell line, so nothing in it can break out.
    @Test func aFolderWithAQuoteIsPassedAsItIs() {
        #expect(plan(cwd: "/tmp/it's here").directory == "/tmp/it's here")
        #expect(plan(cwd: "/tmp/it's here").arguments.allSatisfy { !$0.contains("it's here") })
    }

    @Test func aFolderStartingWithADashIsAPathNotAnOption() {
        #expect(plan(cwd: "-rf").directory == "/Users/me/-rf")
        #expect(plan(cwd: "/tmp/-x").directory == "/tmp/-x")
    }

    @Test func theTildeIsExpandedInSwift() {
        #expect(plan(cwd: "~").directory == "/Users/me")
        #expect(plan(cwd: "~/code/web-app").directory == "/Users/me/code/web-app")
        #expect(plan(cwd: "").directory == "/Users/me")
        #expect(plan(cwd: "~other/x").directory == "/Users/me/~other/x")
    }

    @Test func fishAndOtherShellsFallBackToZsh() {
        for shell in ["/opt/homebrew/bin/fish", "/usr/local/bin/nu", "fish", ""] {
            let plan = plan(shell: shell)
            #expect(plan.executable == "/bin/zsh")
            #expect(plan.arguments.first == "/bin/zsh")
            #expect(plan.shellFallback != nil)
        }
        #expect(plan(shell: "/opt/homebrew/bin/fish").shellFallback == "fish")
        for shell in ["/bin/bash", "/bin/sh", "/bin/dash", "/bin/ksh", "/opt/homebrew/bin/bash"] {
            #expect(plan(shell: shell).executable == shell)
            #expect(plan(shell: shell).shellFallback == nil)
        }
    }

    @Test func theServicesEnvironmentGoesOnTopOfHeadsUps() {
        let definition = ServiceDefinition(
            name: "Web", command: "x",
            env: [EnvironmentVariable(key: "PORT", value: "3000"), EnvironmentVariable(key: "PATH", value: "/opt/bin")])
        let plan = SpawnPlan(
            definition: definition, loginShell: "/bin/zsh", home: home, baseEnvironment: ["PATH": "/usr/bin", "A": "1"])
        #expect(plan.environment == ["A=1", "PATH=/opt/bin", "PORT=3000"])
    }
}

@Suite struct ServiceDefinitionTests {
    @Test func theRulesOfAService() {
        #expect(ServiceDefinition(name: "Web", command: "npm run dev").problems.isEmpty)
        #expect(ServiceDefinition(name: " ", command: "x").problems[.name] != nil)
        #expect(ServiceDefinition(name: String(repeating: "a", count: 65), command: "x").problems[.name] != nil)
        #expect(ServiceDefinition(name: "Web", command: "  ").problems[.command] != nil)
        #expect(ServiceDefinition(name: "Web", command: "x", port: 0).problems[.port] != nil)
        #expect(ServiceDefinition(name: "Web", command: "x", port: 65_536).problems[.port] != nil)
        #expect(ServiceDefinition(name: "Web", command: "x", port: 3000).problems.isEmpty)
        let badKey = ServiceDefinition(name: "Web", command: "x", env: [EnvironmentVariable(key: "1X", value: "")])
        #expect(badKey.problems[.env] != nil)
    }

    @Test func environmentKeys() {
        #expect(EnvironmentVariable.isValidKey("NODE_ENV"))
        #expect(EnvironmentVariable.isValidKey("_x9"))
        #expect(!EnvironmentVariable.isValidKey("9x"))
        #expect(!EnvironmentVariable.isValidKey("A-B"))
        #expect(!EnvironmentVariable.isValidKey("A B"))
        #expect(!EnvironmentVariable.isValidKey(""))
        #expect(!EnvironmentVariable.isValidKey("É"))
    }
}

@Suite struct LogRingTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func outputIsStoredLineByLineEvenWhenChunksCutALine() {
        var ring = LogRing()
        ring.append(output: Data("Listening on ".utf8), at: t)
        #expect(ring.lines.isEmpty)
        ring.append(output: Data(":3000\nready\r\nhalf".utf8), at: t)
        #expect(ring.lines.map(\.text) == ["Listening on :3000", "ready"])
        ring.flush(at: t)
        #expect(ring.lines.map(\.text) == ["Listening on :3000", "ready", "half"])
    }

    @Test func aCharacterCutBetweenChunksStaysWhole() {
        var ring = LogRing()
        let bytes = Array("café\n".utf8)
        ring.append(output: Data(bytes[0..<4]), at: t)
        ring.append(output: Data(bytes[4...]), at: t)
        #expect(ring.lines.map(\.text) == ["café"])
    }

    @Test func itKeepsOnlyTheNewestLinesWithinItsCapacity() {
        var ring = LogRing(capacity: 20)
        for index in 0..<10 { ring.appendLine("line \(index)", at: t) }
        #expect(ring.lines.map(\.text) == ["line 8", "line 9"])
        var big = LogRing()
        for index in 0..<40_000 { big.appendLine("output line number \(index)", at: t) }
        #expect(big.lines.reduce(0) { $0 + $1.text.utf8.count + 1 } <= LogRing.defaultCapacity)
        #expect(big.lines.last?.text == "output line number 39999")
    }

    @Test func clearEmptiesIt() {
        var ring = LogRing()
        ring.appendLine("$ npm run dev", at: t)
        ring.clear()
        #expect(ring.lines.isEmpty)
    }

    @Test func linesReadWithTheirTime() {
        let line = LogLine(time: Date(timeIntervalSince1970: 3600 * 14 + 3 * 60 + 7), text: "ready")
        #expect(LogRing.format(line, timeZone: TimeZone(identifier: "UTC")!) == "14:03:07  ready")
    }
}
