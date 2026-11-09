import ArgumentParser
import KakaoCore

struct CacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Manage the cached KakaoTalk user ID (stored in the macOS Keychain)",
        subcommands: [Clear.self]
    )

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Forget the cached user ID; the next command re-detects it"
        )

        func run() {
            UserIdCache().clear()
            print("Cleared cached user ID.")
        }
    }
}
