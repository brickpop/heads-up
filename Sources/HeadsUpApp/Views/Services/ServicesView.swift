import AppKit
import HeadsUpCore
import SwiftUI

/// The Services tab: the header and its note, the isolation notice, then the services, or
/// the file problem, or the empty state. It redraws once a second while the HUD is open, for
/// the uptimes, and scrolls past 480 pt.
struct ServicesView: View {
    let model: AppModel
    let isOpen: Bool

    private let contentHeight = State<CGFloat>(initialValue: 0)

    var body: some View {
        EverySecond(isRunning: isOpen) { now in
            let screen = model.services.screen(at: now)
            ScrollView {
                ServicesContent(model: model, screen: screen)
                    .padding(HUDStyle.Services.padding)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        contentHeight.wrappedValue = $0
                    }
            }
            .frame(height: min(contentHeight.wrappedValue, HUDStyle.Services.maxHeight))
        }
    }
}

private struct ServicesContent: View {
    let model: AppModel
    let screen: ServicesScreen

    var body: some View {
        let services = model.services
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    FocusLabel(text: screen.label)
                    if let note = screen.note {
                        Text(note)
                            .font(.system(size: HUDStyle.Footer.fontSize))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button(screen.edit, action: model.openServicesSettings)
                    .buttonStyle(.ghost)
            }
            .padding(.horizontal, HUDStyle.Services.headerPadding)
            .padding(.vertical, HUDStyle.Footer.keyGap)

            if let notice = screen.isolationNotice {
                NoticeBar(text: notice.title, detail: notice.text) {
                    Button(notice.ok, action: services.dismissIsolationNotice)
                        .buttonStyle(.hud(.secondary))
                }
            }

            if let problem = screen.fileProblem {
                FileProblemCardView(
                    card: problem, inHUD: true, reveal: services.revealServicesFile, retry: services.reloadServices)
            } else if let empty = screen.empty {
                ServicesEmptyView(empty: empty, add: model.addService)
            } else {
                ForEach(screen.rows) { row in
                    ServiceRowView(model: model, row: row)
                }
            }
        }
    }
}

/// No services yet: a chip, the title and one line, and Add a service….
private struct ServicesEmptyView: View {
    let empty: ServicesScreen.Empty
    let add: @MainActor () -> Void

    var body: some View {
        VStack(spacing: HUDStyle.Settings.sectionSpacing) {
            Image(systemName: Glyph.servers.symbolName)
                .font(.system(size: HUDStyle.Suggestions.chipIconSize))
                .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
                .background(
                    HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                )
                .accessibilityHidden(true)
            Text(empty.title)
                .font(.system(size: HUDStyle.Services.emptyTitleSize, weight: .semibold))
            Text(empty.text)
                .font(.system(size: HUDStyle.Settings.labelSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(empty.add, action: add)
                .buttonStyle(.hud(.secondary))
        }
        .frame(maxWidth: .infinity)
        .padding(HUDStyle.Welcome.padding)
    }
}

/// One service: chip with status dot, name and meta, the mono command line, Logs, and
/// Start or Stop; its log drawer under it while open. A running service with a port opens in the
/// browser from a click on the row outside its buttons, `:port` included. While the pointer is
/// over it, the row takes the --raise fill, as a Commands row does; only the `:port` takes the
/// pointing hand and the underline.
private struct ServiceRowView: View {
    let model: AppModel
    let row: ServicesScreen.Row

    /// The pointer is over the clickable part, while it opens in the browser.
    private let rowHovered = State<Bool>(initialValue: false)
    /// The pointer is over the `:port`, with the pointing hand pushed.
    private let portHovered = State<Bool>(initialValue: false)

    var body: some View {
        let services = model.services
        VStack(alignment: .leading, spacing: HUDStyle.Services.padding) {
            HStack(spacing: HUDStyle.Services.rowGap) {
                HStack(spacing: HUDStyle.Services.rowGap) {
                    ServiceChip(status: row.status)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: HUDStyle.Footer.keyGap) {
                            Text(row.name)
                                .font(.system(size: HUDStyle.Suggestions.titleSize, weight: .semibold))
                            if let meta = row.meta {
                                metaView(meta)
                                    .font(.system(size: HUDStyle.Services.metaSize).monospacedDigit())
                                    .foregroundStyle(metaColor)
                            }
                            ServiceFlags(row: row)
                        }
                        .lineLimit(1)
                        Text(row.commandLine)
                            .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.accessibilityLabel)
                    // "restarting in 5 seconds" while it waits: read when focused, never announced.
                    .accessibilityValue(row.accessibilityValue ?? "")
                    .accessibilityActions {
                        if let link = row.link {
                            Button(link.accessibilityAction, action: openInBrowser)
                        }
                    }
                    Spacer(minLength: HUDStyle.Services.rowGap)
                }
                .modifier(OpensInBrowser(link: row.link, hovering: rowHovered.projectedValue, open: openInBrowser))
                LogsToggle(isOpen: row.logsOpen, warning: row.logsWarning) { services.toggleLogs(row.id) }
                RowActionButton(
                    action: row.action, run: { services.toggleRun(row.id) }, edit: { model.editService(row.id) })
            }
            if let log = row.log {
                LogDrawer(log: log) { services.clearLogs(row.id) }
            }
        }
        .padding(HUDStyle.Services.rowPadding)
        .background(
            row.logsOpen || (rowHovered.wrappedValue && row.link != nil) ? HUDStyle.Colors.raise : Color.clear,
            in: RoundedRectangle(cornerRadius: HUDStyle.Services.rowCornerRadius)
        )
        // A link that goes, or a row that goes, gives the arrow back.
        .onChange(of: row.link == nil) { _, gone in if gone { setPortHovered(false) } }
        .onDisappear { setPortHovered(false) }
        // Any close (Esc, the wake shortcut, a click outside) leaves no mouse-exit behind.
        .onChange(of: model.hud.isOpen) { _, open in if !open { setPortHovered(false) } }
    }

    private func openInBrowser() {
        // The HUD closes under the pointer, and no mouse-exit follows: give the arrow back first,
        // or the next open would show the hand away from any link.
        setPortHovered(false)
        model.openServiceInBrowser(row.id)
    }

    /// The meta. While the row opens in the browser, its `:port` takes the pointing hand and the
    /// underline when the pointer is over it.
    @ViewBuilder private func metaView(_ meta: String) -> some View {
        if let link = row.link, let range = meta.range(of: link.portLabel) {
            HStack(spacing: 0) {
                Text(meta[..<range.lowerBound])
                Text(link.portLabel)
                    .underline(portHovered.wrappedValue)
                    .onHover { setPortHovered($0) }
                Text(meta[range.upperBound...])
            }
        } else {
            Text(meta)
        }
    }

    /// Pushes the pointing hand once, and pops it once.
    private func setPortHovered(_ on: Bool) {
        guard on != portHovered.wrappedValue else { return }
        portHovered.wrappedValue = on
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    private var metaColor: Color {
        switch row.metaStyle {
        case .accent: .accentColor
        case .warn: HUDStyle.Colors.warn
        case .secondary: .secondary
        }
    }
}

/// The part of a row that opens a running service in the browser: it takes the click, and says
/// while the pointer is over it, for the row's fill, with "Open localhost:3000" as its tooltip.
/// The cursor stays the arrow here. Without a link it does nothing.
private struct OpensInBrowser: ViewModifier {
    let link: ServicesScreen.Link?
    let hovering: Binding<Bool>
    let open: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { if link != nil { open() } }
            .onHover { inside in hovering.wrappedValue = inside && link != nil }
            .help(link?.help ?? "")
    }
}

/// The flags' glyphs after the meta, 11 pt and secondary, each shown while its flag is on, with
/// a tooltip. The cup's tooltip follows its hold; it turns --warn when macOS refused it, and
/// tertiary once its limit ended. VoiceOver reads them through the row's label instead.
private struct ServiceFlags: View {
    let row: ServicesScreen.Row

    var body: some View {
        HStack(spacing: HUDStyle.Services.flagGap) {
            if row.keepsAwake {
                Image(systemName: Symbols.keepsAwake)
                    .foregroundStyle(cupStyle)
                    .help(row.keepAwakeHelp)
            }
            if row.restarts {
                Image(systemName: Symbols.restarts)
                    .help(Strings.Services.restartsHelp)
            }
        }
        .font(.system(size: HUDStyle.Services.flagSize))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var cupStyle: AnyShapeStyle {
        if row.awake == .refused { return AnyShapeStyle(HUDStyle.Colors.warn) }
        return row.keepAwakeEnded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
    }
}

/// The row's button, 84 pt wide: Start (primary) or Stop (secondary), or Edit… (secondary)
/// for a hand-edited service that breaks a rule and can't start; its meta says why.
private struct RowActionButton: View {
    let action: ServicesScreen.RowAction
    let run: @MainActor () -> Void
    let edit: @MainActor () -> Void

    var body: some View {
        switch action {
        case .run(let title, let glyph, let isPrimary):
            let button = Button(action: run) {
                Label(title, systemImage: glyph.symbolName)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: HUDStyle.Services.buttonWidth)
            if isPrimary {
                button.buttonStyle(.hud(.primary))
            } else {
                button.buttonStyle(.hud(.secondary))
            }
        case .edit(let title):
            Button(action: edit) {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.hud(.secondary))
            .frame(width: HUDStyle.Services.buttonWidth)
        }
    }
}

/// The server chip, with the status dot at its bottom-right corner: green running, a hollow
/// accent ring starting, gray stopped, red with × failed. VoiceOver reads the status in the row.
private struct ServiceChip: View {
    let status: ServicesScreen.Status

    var body: some View {
        Image(systemName: Glyph.server.symbolName)
            .font(.system(size: HUDStyle.Suggestions.chipIconSize))
            .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
            .background(HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius))
            .overlay(alignment: .bottomTrailing) { dot.offset(x: 2, y: 2) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var dot: some View {
        let size = HUDStyle.Services.statusDotSize
        switch status {
        case .running:
            Circle().fill(HUDStyle.Colors.running).frame(width: size, height: size)
        case .starting:
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: size, height: size)
        case .stopped:
            Circle().fill(HUDStyle.Colors.track).frame(width: size, height: size)
        case .failed:
            Image(systemName: Symbols.failedDot)
                .font(.system(size: size))
                .foregroundStyle(HUDStyle.Colors.alert)
        }
    }
}

/// The Logs toggle: an icon-only card button with the list icon, on while the drawer is
/// open, with a --warn dot while the service's port stays silent.
private struct LogsToggle: View {
    let isOpen: Bool
    let warning: Bool
    let toggle: @MainActor () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOpen }, set: { _ in toggle() })) {
            Label(Strings.Services.logs, systemImage: Symbols.logs)
        }
        // A button-style toggle draws with the button style, and VoiceOver still reads it as a
        // toggle button, on or off.
        .toggleStyle(.button)
        .buttonStyle(.hud(.iconOnly(isOn: isOpen)))
        .help(Strings.Services.logsHelp(isOpen: isOpen))
        .overlay(alignment: .topTrailing) {
            if warning {
                Circle()
                    .fill(HUDStyle.Colors.warn)
                    .frame(width: HUDStyle.Services.warningDotSize, height: HUDStyle.Services.warningDotSize)
                    .padding(HUDStyle.Services.warningDotInset)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The log drawer: 180 pt of mono lines on the code background, newest at the bottom, with
/// Clear at the bottom right.
private struct LogDrawer: View {
    let log: ServicesScreen.Log
    let clear: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: HUDStyle.Services.logLineSpacing) {
                        if let empty = log.emptyText {
                            Text(empty).foregroundStyle(.secondary)
                        }
                        ForEach(log.lines, id: \.id) { line in
                            HStack(alignment: .firstTextBaseline, spacing: HUDStyle.Services.logTimeGap) {
                                Text(line.time).foregroundStyle(.tertiary)
                                Text(line.text)
                            }
                            .id(line.id)
                        }
                    }
                    .font(.system(size: HUDStyle.Services.logFontSize).monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: log.lines.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Button(log.clear, action: clear)
                .buttonStyle(.ghost)
        }
        .padding(HUDStyle.Services.drawerPadding)
        .frame(height: HUDStyle.Services.drawerHeight)
        .background(
            HUDStyle.Colors.codeBackground, in: RoundedRectangle(cornerRadius: HUDStyle.Services.drawerCornerRadius)
        )
        .padding(.leading, HUDStyle.Services.drawerLeading - HUDStyle.Services.rowPadding)
    }
}

/// Has VoiceOver say, once, that a service kept stopping and HeadsUp gave up on it
/// (UX: service flags §4), while the HUD is open, whichever tab shows. It sits on the HUD's
/// root, which is always there, rather than on the row, which exists only on the Services tab.
struct GaveUpAnnouncer: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.onChange(of: gaveUp) { old, new in
            guard model.hud.isOpen else { return }
            for definition in model.services.definitions
            where new.contains(definition.id) && !old.contains(definition.id) {
                AccessibilityNotification.Announcement(Strings.Services.gaveUpAnnouncement(definition.name)).post()
            }
        }
    }

    /// The services that gave up restarting.
    private var gaveUp: Set<ServiceDefinition.ID> {
        Set(
            model.services.definitions.map(\.id).filter { id in
                if case .failed(_, _, _?) = model.services.state(id) { return true }
                return false
            })
    }
}
