import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The user's account, for services.
public enum UserAccount {
    /// The login shell from the user database, or /bin/zsh, macOS's default.
    public static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.isEmpty ? "/bin/zsh" : path
    }
}
