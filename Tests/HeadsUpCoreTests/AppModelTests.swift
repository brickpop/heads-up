import Foundation
import Testing

@testable import HeadsUpCore

// The CGRect and CGPoint initializers come from CoreGraphics on Apple's platforms (see
// HUDLayout.swift); Linux's Foundation has its own.
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

@MainActor
private func action(_ id: String, in model: AppModel) -> Action? {
    model.registry.actions.first { $0.id == ActionID(id) }
}

@MainActor
@Suite struct AppModelTests {
    @Test func theCatalogueListsFocusCaffeineAddAModelPinnedThemeAndGoTo() {
        let model = AppModel.preview()
        #expect(
            model.registry.actions.map(\.id.rawValue) == [
                "focus.start:25", "focus.start:40", "focus.start:50", "focus.break",
                "caffeine.on:oneHour", "caffeine.on:twoHours", "caffeine.on:untilOff",
                "model.add", "chat.pinned", "chat.new", "theme.toggle",
                "view.open:chat", "view.open:focus", "view.open:caffeine",
                "view.open:services", "view.open:commands", "view.open:settings",
            ])
    }

    @Test func goToSelectsItsTab() throws {
        let model = AppModel.preview()
        let goTo = try #require(action("view.open:services", in: model))
        #expect(goTo.title == "Go to Services")
        #expect(goTo.subtitle == "view · ⌘4")
        #expect(goTo.suggest == .oneClick)
        goTo.run()
        #expect(model.hud.tab == .services)
        #expect(model.hud.isOpen)
    }

    @Test func pomodoroFindsGoToFocus() {
        let model = AppModel.preview()
        model.hud.setInput("/pomodoro")
        #expect(
            model.hud.suggestions.map { row -> String in
                if case .action(let action) = row { return action.title }
                return "?"
            } == ["Start 25 min focus", "Start 40 min focus", "Start 50 min focus", "Take a break now", "Go to Focus"])
    }

    @Test func addAModelOpensSettingsModels() throws {
        let model = AppModel.preview()
        model.hud.open(tab: .focus)
        try #require(action("model.add", in: model)).run()
        #expect(model.hud.tab == .settings)
        #expect(model.hud.settingsSection == .models)
    }

    @Test func toggleThemeFlipsWhatYouSeeAndStoresItAsAChoice() throws {
        let model = AppModel.preview(systemIsDark: true)
        let toggle = try #require(action("theme.toggle", in: model))
        #expect(toggle.subtitle == "appearance · System (Dark) → Light")
        toggle.run()
        #expect(model.settings.settings.general.appearance == .light)

        let again = try #require(action("theme.toggle", in: model))
        #expect(again.subtitle == "appearance · Light → Dark")
        let useSystem = try #require(action("theme.system", in: model))
        #expect(useSystem.subtitle == "appearance · Light → System")
        useSystem.run()
        #expect(model.settings.settings.general.appearance == .system)
        #expect(action("theme.system", in: model) == nil)
    }

    @Test func launchRegistersTheWakeShortcut() {
        #expect(AppModel.preview().hud.hotkey == .ok(.wakeDefault))
        #expect(AppModel.preview(hotkey: .reservedBySystem).hud.hotkey == .reservedBySystem)
    }

    @Test func noTabShowsActivityYet() {
        #expect(AppModel.preview().tabActivity.isEmpty)
    }
}

@Suite struct StringsTests {
    @Test func tabTooltipsNameTheirShortcut() {
        #expect(Strings.Tabs.tooltip(.focus) == "Focus · ⌘2")
        #expect(Strings.Tabs.tooltip(.settings) == "Settings · ⌘6")
    }

    @Test func shortcutsReadAsOnTheirKeycaps() {
        #expect(Shortcut.wakeDefault.displayName == "⌥ Space")
        #expect(Shortcut.wakeDefault.keycaps == ["⌥", "Space"])
        let shortcut = Shortcut(keyCode: 40, modifiers: [.command, .shift, .control, .option], key: "K")
        #expect(shortcut.keycaps == ["⌃", "⌥", "⇧", "⌘", "K"])
        #expect(shortcut.displayName == "⌃⌥⇧⌘K")
    }

    @Test func eachHotkeyProblemHasItsCopy() {
        let space = Shortcut.wakeDefault
        #expect(Strings.Hotkey.problem(.ok(space), shortcut: space) == nil)
        #expect(
            Strings.Hotkey.problem(.reservedBySystem, shortcut: space)
                == "⌥ Space is used by macOS. Choose another, or turn it off in "
                + "System Settings → Keyboard → Keyboard Shortcuts.")
        #expect(
            Strings.Hotkey.problem(.failed(-9878), shortcut: space)
                == "HeadsUp couldn't set up ⌥ Space. Choose another shortcut, or try again.")
    }

    @Test func tabsKnowTheirCommandNumber() {
        #expect(Tab.allCases.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(Tab(number: 0) == nil)
        #expect(Tab(number: 7) == nil)
    }
}

@MainActor
@Suite struct CatalogueOrderTests {
    @Test func sectionsListInCatalogueOrderWhateverOrderTheyWereAdded() {
        let registry = ActionRegistry()
        func provider(_ id: String) -> ActionRegistry.Provider {
            {
                [
                    Action(
                        id: ActionID(id), title: id, subtitle: "", kind: .action, glyph: .plus, keywords: "",
                        suggest: .never, run: {})
                ]
            }
        }
        registry.add(.view, provider("view"))
        registry.add(.focus, provider("focus"))
        registry.add(.command, provider("command"))
        registry.add(.caffeine, provider("caffeine"))
        registry.add(.chat, provider("chat"))
        registry.add(.model, provider("model"))
        registry.add(.theme, provider("theme"))
        registry.add(.service, provider("service"))
        registry.add(.focus, provider("focus 2"))
        #expect(
            registry.actions.map(\.id.rawValue) == [
                "focus", "focus 2", "caffeine", "model", "service", "command", "chat", "theme", "view",
            ])
    }
}

@MainActor
@Suite struct SettingsNoticeTests {
    @Test func noProblemNoNotice() {
        #expect(AppModel.preview().settingsNotice == nil)
    }

    @Test func theNoticeShowsOnOneHUDOpen() {
        let model = AppModel.preview(settingsFileProblem: .newerVersion(URL(fileURLWithPath: "/tmp/settings.json")))
        #expect(model.settingsNotice == "These settings are from a newer version of HeadsUp")
        model.hud.open()
        #expect(model.settingsNotice != nil)
        model.hud.close()
        #expect(model.settingsNotice == nil)
        model.hud.open()
        #expect(model.settingsNotice == nil)
    }

    @Test func theCrossDismissesIt() {
        let model = AppModel.preview(settingsFileProblem: .unreadable(URL(fileURLWithPath: "/tmp/settings.json")))
        model.hud.open()
        model.dismissSettingsNotice()
        #expect(model.settingsNotice == nil)
        #expect(model.hud.isOpen)
    }

    @Test func openSettingsGoesToGeneralAndDismissesIt() {
        let model = AppModel.preview(settingsFileProblem: .saveFailed("The disk is full."))
        model.hud.open(tab: .focus)
        model.openSettingsFromNotice()
        #expect(model.settingsNotice == nil)
        #expect(model.hud.tab == .settings)
        #expect(model.hud.settingsSection == .general)
    }

    @Test func eachProblemHasItsTitle() {
        let file = URL(fileURLWithPath: "/tmp/settings.json")
        #expect(Strings.SettingsFile.title(.keptAside(file)) == "HeadsUp started with default settings")
        #expect(Strings.SettingsFile.title(.unreadable(file)) == "Your settings aren't being saved")
        #expect(Strings.SettingsFile.title(.saveFailed("x")) == "Settings couldn't be saved")
    }
}

@Suite struct HUDLayoutTests {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func centredWith108PointsAboveAndGrowingDown() {
        let frame = HUDLayout.frame(screen: laptop, contentHeight: 102)
        #expect(frame == CGRect(x: 376, y: 982 - 108 - 102, width: 760, height: 102))
        let taller = HUDLayout.frame(screen: laptop, contentHeight: 400)
        #expect(taller.maxY == frame.maxY)
    }

    @Test func narrowScreensKeep16PointsEachSide() {
        let narrow = CGRect(x: 0, y: 0, width: 700, height: 800)
        #expect(HUDLayout.frame(screen: narrow, contentHeight: 102).width == 668)
        #expect(HUDLayout.frame(screen: narrow, contentHeight: 102).minX == 16)
    }

    @Test func aSecondScreenUsesItsOwnCoordinates() {
        let second = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let frame = HUDLayout.frame(screen: second, contentHeight: 102)
        #expect(frame.midX == second.midX)
        #expect(frame.maxY == second.maxY - 108)
    }

    @Test func itStopsShortOfTheBottomOfTheScreen() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 500)
        let frame = HUDLayout.frame(screen: short, contentHeight: 900)
        #expect(frame.minY == 16, "\(frame)")
        #expect(frame.maxY == 392, "\(frame)")
    }
}

@Suite struct TabAccessibilityTests {
    @Test func tabsReadTheirStateAsInTheDesign() {
        #expect(Strings.Tabs.accessibilityValue(.focus, selected: true, activity: .active) == "selected")
        #expect(Strings.Tabs.accessibilityValue(.focus, selected: false, activity: .active) == "timer running")
        #expect(Strings.Tabs.accessibilityValue(.caffeine, selected: false, activity: .active) == "on")
        #expect(Strings.Tabs.accessibilityValue(.services, selected: false, activity: .alert) == "failed")
        #expect(Strings.Tabs.accessibilityValue(.chat, selected: false, activity: nil) == "")
    }
}

@Suite struct HUDScreenTests {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

    @Test func theHUDOpensOnTheScreenUnderThePointer() {
        #expect(HUDLayout.screen(under: CGPoint(x: -500, y: 300), in: [main, left]) == left)
        #expect(HUDLayout.screen(under: CGPoint(x: 700, y: 300), in: [main, left]) == main)
    }

    @Test func withThePointerOffEveryScreenItUsesTheMainOne() {
        #expect(HUDLayout.screen(under: CGPoint(x: 9000, y: 9000), in: [main, left]) == main)
        #expect(HUDLayout.screen(under: .zero, in: []) == nil)
    }
}
