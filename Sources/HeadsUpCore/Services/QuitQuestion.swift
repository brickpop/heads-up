/// The alert before quitting while services run, ready to show.
public struct QuitQuestion: Equatable, Sendable {
    public let title: String
    public let message: String
    /// "Your focus timer and Caffeine also stop.", when either is on.
    public let detail: String?
    /// The default button: Quit and Terminate.
    public let quit: String
    public let cancel: String
}
