import Foundation

/// Remembers the resolved KakaoTalk user ID in the login Keychain, so the SHA-512 search runs once.
///
/// Stores only the user ID — never the derived database key or passphrase. Uses the `security`
/// CLI like CredentialStore (no per-binary ACL prompts across rebuilds).
public struct UserIdCache: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "com.kakaocli.cache", account: String = "kakaotalk-user-id") {
        self.service = service
        self.account = account
    }

    public func read() -> Int? {
        CredentialStore.readKeychain(service: service, account: account).flatMap { Int($0) }
    }

    public func write(_ userId: Int) {
        try? CredentialStore.writeKeychain(service: service, account: account, value: String(userId))
    }

    public func clear() {
        CredentialStore.deleteKeychain(service: service, account: account)
    }
}

public enum UserIdResolver {
    /// Find the user ID whose derived key opens the database (`opens` returns true).
    ///
    /// Order: `KAKAOCLI_USER_ID` (authoritative, no fallback) → cached id → `detect`
    /// (plist heuristics, then brute force) → AlertKakaoIDsList candidates.
    /// A cached id that no longer matches the active-account hash or no longer opens the
    /// database is cleared and re-resolved; a newly resolved id is written back to the cache.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cache: UserIdCache?,
        activeHash: () -> String? = DeviceInfo.activeAccountHash,
        detect: () throws -> Int = DeviceInfo.userId,
        candidates: () -> [Int] = DeviceInfo.candidateUserIds,
        opens: (Int) -> Bool
    ) throws -> Int {
        if let id = try DeviceInfo.userIdOverride(environment: environment) {
            guard opens(id) else {
                throw KakaoError.userIdResolution(
                    "\(DeviceInfo.userIdEnvVar) is set, but the key derived from it does not open the database")
            }
            return id
        }

        var tried = Set<Int>()
        if let cache, let cached = cache.read() {
            // The hash check catches account switches: the old account's DB file may still open.
            if activeHash().map({ DeviceInfo.userId(cached, matchesHash: $0) }) ?? true, opens(cached) {
                return cached
            }
            cache.clear()
            tried.insert(cached)
        }

        var detectError = ""
        var ids: [Int] = []
        do { ids.append(try detect()) } catch { detectError = " (\(error))" }
        for id in ids + candidates() where tried.insert(id).inserted {
            if opens(id) {
                cache?.write(id)
                return id
            }
        }
        throw KakaoError.userIdResolution(
            "Could not find a user ID that opens the KakaoTalk database\(detectError). "
            + "Set \(DeviceInfo.userIdEnvVar), or raise KAKAOCLI_BRUTE_FORCE_MAX / KAKAOCLI_BRUTE_FORCE_TIMEOUT.")
    }
}
