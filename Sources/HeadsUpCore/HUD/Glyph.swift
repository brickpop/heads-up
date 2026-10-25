/// The icons the core names. The app maps each one to an SF Symbol,
/// so symbol names live only in the view layer.
public enum Glyph: String, CaseIterable, Sendable {
    // Tabs
    case chat, timer, cup, servers, terminal, sliders
    // Actions
    case sparkle, stop, droplet, plus, cpu, server, pin
    // Menu bar
    case pause
    // Settings
    case folder
}
