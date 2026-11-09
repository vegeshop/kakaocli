import CommonCrypto
import Foundation
import IOKit
import os

/// Extracts device UUID and KakaoTalk user ID from the local system.
public enum DeviceInfo {

    /// Get the IOPlatformUUID from IORegistry (same value `ioreg -rd1 -c IOPlatformExpertDevice` prints).
    public static func platformUUID() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0,
              let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        else {
            throw KakaoError.uuidNotFound
        }
        return uuid
    }

    /// Path to the KakaoTalk preferences plist.
    public static var preferencesPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Preferences/com.kakao.KakaoTalkMac.plist"
    }

    /// Path to the KakaoTalk container data directory.
    public static var containerPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
    }

    /// Path to the container preferences plist (has more data than the global one).
    public static var containerPreferencesPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefDir = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Preferences"
        // Find the hex-suffixed plist: com.kakao.KakaoTalkMac.<HEX>.plist
        if let files = try? FileManager.default.contentsOfDirectory(atPath: prefDir) {
            for file in files where file.hasPrefix("com.kakao.KakaoTalkMac.") && file.hasSuffix(".plist") && file != "com.kakao.KakaoTalkMac.plist" {
                return "\(prefDir)/\(file)"
            }
        }
        return "\(prefDir)/com.kakao.KakaoTalkMac.plist"
    }

    /// Environment variable that pins the user ID and skips all detection.
    public static let userIdEnvVar = "KAKAOCLI_USER_ID"

    /// The `KAKAOCLI_USER_ID` override, or nil if unset. Throws if it is set but not a positive integer.
    public static func userIdOverride(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Int? {
        guard let raw = environment[userIdEnvVar] else { return nil }
        guard let id = Int(raw.trimmingCharacters(in: .whitespaces)), id > 0 else {
            throw KakaoError.userIdResolution("\(userIdEnvVar) must be a positive integer")
        }
        return id
    }

    // ponytail: process-lifetime memo so callers that ask more than once (sync/harvest fallback
    // paths) never repeat a brute-force search. Cross-run caching lives in UserIdCache.
    private static let userIdMemo = OSAllocatedUnfairLock<Result<Int, any Error>?>(initialState: nil)

    /// Detect the logged-in user ID. Cheapest sources first:
    /// 1. `KAKAOCLI_USER_ID` environment variable
    /// 2. FSChatWindowTransparency common suffix / direct keys (legacy plists)
    /// 3. FSChatWindowFrame_ suffix and AlertKakaoIDsList, checked against the active-account SHA-512 hash
    /// 4. Parallel brute force of that hash's pre-image (last resort)
    /// 5. FSChatWindowFrame_ suffix unconfirmed (when there is no hash, or the search failed)
    public static func userId() throws -> Int {
        if let memo = userIdMemo.withLock({ $0 }) { return try memo.get() }
        let result = Result { try detectUserId() }
        userIdMemo.withLock { $0 = result }
        return try result.get()
    }

    private static func detectUserId() throws -> Int {
        if let id = try userIdOverride() { return id }

        var plists: [[String: Any]] = []
        for plistPath in [containerPreferencesPath, preferencesPath] where FileManager.default.fileExists(atPath: plistPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                plists.append(plist)
            }
        }

        for plist in plists {
            if let id = commonSuffixId(in: plist, keyPrefix: "FSChatWindowTransparency") { return id }
            for key in ["userId", "user_id", "KAKAO_USER_ID", "userID"] {
                if let id = plist[key] as? Int { return id }
                if let str = plist[key] as? String, let id = Int(str) { return id }
            }
        }

        // Newer KakaoTalk only identifies the active account by SHA-512(userId), stored as the
        // suffix of keys like "DESIGNATEDFRIENDSREVISION:<sha512hex>" (non-zero for the active account).
        let frameIds = plists.compactMap { commonSuffixId(in: $0, keyPrefix: "NSWindow Frame FSChatWindowFrame_") }
        if let hash = plists.lazy.compactMap(activeAccountHash(from:)).first {
            if let id = (frameIds + candidateUserIds()).first(where: { userId($0, matchesHash: hash) }) {
                return id
            }
            if let id = recoverUserIdFromSHA512(hexHash: hash) { return id }
        }
        if let id = frameIds.first { return id }

        throw KakaoError.userIdNotFound(["Could not extract from FSChatWindowTransparency, revision key SHA-512, or FSChatWindowFrame_ keys"])
    }

    private static func commonSuffixId(in plist: [String: Any], keyPrefix: String) -> Int? {
        let suffixes = plist.keys.filter { $0.hasPrefix(keyPrefix) }.map { String($0.dropFirst(keyPrefix.count)) }
        guard suffixes.count >= 2, let common = longestCommonSuffix(suffixes) else { return nil }
        return Int(common)
    }

    /// Read AlertKakaoIDsList from plist as candidate user IDs.
    public static func candidateUserIds() -> [Int] {
        let plistPaths = [containerPreferencesPath, preferencesPath]
        for plistPath in plistPaths {
            guard FileManager.default.fileExists(atPath: plistPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let ids = plist["AlertKakaoIDsList"] as? [Any] else { continue }

            return ids.compactMap { item -> Int? in
                if let id = item as? Int { return id > 0 ? id : nil }
                if let str = item as? String, let id = Int(str) { return id > 0 ? id : nil }
                return nil
            }
        }
        return []
    }

    /// Discover database file by scanning the container for 78-char hex filenames.
    public static func discoverDatabaseFile() -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: containerPath) else { return nil }
        let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}$")
        for entry in entries {
            let range = NSRange(entry.startIndex..., in: entry)
            if hexPattern.firstMatch(in: entry, range: range) != nil {
                return "\(containerPath)/\(entry)"
            }
        }
        // Also check files with .db extension that have hex basename
        let hexDbPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}\\.db$")
        for entry in entries {
            let range = NSRange(entry.startIndex..., in: entry)
            if hexDbPattern.firstMatch(in: entry, range: range) != nil {
                return "\(containerPath)/\(entry)"
            }
        }
        return nil
    }

    /// Count database files in the container (78-char hex files or .db files).
    public static func countDatabaseFiles() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: containerPath) else { return 0 }
        let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}(\\.db)?$")
        return entries.filter { entry in
            let range = NSRange(entry.startIndex..., in: entry)
            return hexPattern.firstMatch(in: entry, range: range) != nil
        }.count
    }

    /// Extract the active account SHA-512 hash from plist revision keys.
    /// Keys like `DESIGNATEDFRIENDSREVISION:<sha512hex>` appear with non-zero values for the active account.
    /// SHA-512("0") is the default/empty account hash.
    public static func activeAccountHash() -> String? {
        let plistPaths = [containerPreferencesPath, preferencesPath]
        for plistPath in plistPaths {
            guard FileManager.default.fileExists(atPath: plistPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            if let hash = activeAccountHash(from: plist) {
                return hash
            }
        }
        return nil
    }

    private static func activeAccountHash(from plist: [String: Any]) -> String? {
        // SHA-512("0") = 31bca02... is the default/empty account
        let emptyHash = "31bca02094eb78126a517b206a88c73cfa9ec6f704c7030d18212cace820f025f00bf0ea68dbf3f3a5436ca63b53bf7bf80ad8d5de7d8359d0b7fed9dbc3ab99"
        let prefix = "DESIGNATEDFRIENDSREVISION:"
        for (key, val) in plist where key.hasPrefix(prefix) {
            let hash = String(key.dropFirst(prefix.count))
            if hash == emptyHash { continue }
            let intVal: Int
            if let v = val as? Int { intVal = v }
            else if let v = val as? Double { intVal = Int(v) }
            else { intVal = 0 }
            if intVal != 0 { return hash }
        }
        return nil
    }

    /// Whether SHA-512 of the decimal string of `id` equals `hexHash`.
    public static func userId(_ id: Int, matchesHash hexHash: String) -> Bool {
        guard let target = bytes(fromHex: hexHash) else { return false }
        let digits = Array(String(id).utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512(digits, CC_LONG(digits.count), &hash)
        return hash == target
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count == 128 else { return nil }
        var out: [UInt8] = []
        for i in stride(from: 0, to: 128, by: 2) {
            guard let byte = UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// Search bound for the brute force (`KAKAOCLI_BRUTE_FORCE_MAX`, default 4,000,000,000).
    public static var bruteForceMax: Int {
        ProcessInfo.processInfo.environment["KAKAOCLI_BRUTE_FORCE_MAX"].flatMap { Int($0) } ?? 4_000_000_000
    }

    /// Brute-force time budget in seconds (`KAKAOCLI_BRUTE_FORCE_TIMEOUT`, default 60).
    public static var bruteForceTimeout: Double {
        ProcessInfo.processInfo.environment["KAKAOCLI_BRUTE_FORCE_TIMEOUT"].flatMap { Double($0) } ?? 60
    }

    /// Recover a userId by brute-forcing the SHA-512 pre-image of `hexHash` over `0..<maxId`.
    ///
    /// All cores pull ~1M-id chunks in ascending order from a shared counter, so small ids are
    /// found first and every worker stops as soon as one finds a match or the timeout passes.
    /// Progress goes to stderr only; the recovered id is never printed.
    public static func recoverUserIdFromSHA512(
        hexHash: String,
        maxId: Int = bruteForceMax,
        timeout: Double = bruteForceTimeout,
        progress: Bool = true
    ) -> Int? {
        guard let target = bytes(fromHex: hexHash), maxId > 0 else { return nil }

        struct Search { var next = 0, done = 0, found: Int?, stop = false, lastReport = 0.0 }
        let state = OSAllocatedUnfairLock(initialState: Search())
        let chunkSize = 1 << 20
        let chunks = (maxId + chunkSize - 1) / chunkSize
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let start = CFAbsoluteTimeGetCurrent()
        if progress {
            fputs("kakaocli: recovering KakaoTalk user ID from the preferences hash "
                  + "(ids < \(maxId), timeout \(Int(timeout))s, \(cores) cores)...\n", stderr)
        }

        DispatchQueue.concurrentPerform(iterations: cores) { _ in
            var digits = [UInt8](repeating: 0, count: 20)
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            while let chunk = state.withLock({ s -> Int? in
                guard !s.stop, s.next < chunks else { return nil }
                defer { s.next += 1 }
                return s.next
            }) {
                let lo = chunk * chunkSize, hi = min(lo + chunkSize, maxId)
                let hit: Int? = digits.withUnsafeMutableBufferPointer { buf in
                    hash.withUnsafeMutableBufferPointer { out in
                        for i in lo..<hi {
                            if i & 0xFFFF == 0 {  // every 65k ids: honor a match elsewhere or the deadline
                                let late = CFAbsoluteTimeGetCurrent() - start > timeout
                                if state.withLock({ s in s.stop = s.stop || late; return s.stop }) { return nil }
                            }
                            // Decimal digits of i, right-aligned in buf (no per-id allocation).
                            var n = i, p = buf.count
                            repeat { p -= 1; buf[p] = UInt8(truncatingIfNeeded: 48 + n % 10); n /= 10 } while n > 0
                            CC_SHA512(buf.baseAddress! + p, CC_LONG(buf.count - p), out.baseAddress!)
                            if memcmp(out.baseAddress!, target, target.count) == 0 { return i }
                        }
                        return nil
                    }
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let report: String? = state.withLock { s in
                    if let hit { s.found = hit; s.stop = true }
                    s.done += 1
                    if elapsed > timeout { s.stop = true }
                    guard progress, !s.stop, elapsed - s.lastReport >= 2 else { return nil }
                    s.lastReport = elapsed
                    return "kakaocli: ... \(s.done * 100 / chunks)% of search space, \(Int(elapsed))s elapsed\n"
                }
                if let report { fputs(report, stderr) }
            }
        }

        let found = state.withLock { $0.found }
        if progress {
            let elapsed = String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - start)
            fputs(found != nil
                  ? "kakaocli: user ID recovered in \(elapsed)\n"
                  : "kakaocli: user ID not recovered after \(elapsed). Set KAKAOCLI_USER_ID, or raise "
                    + "KAKAOCLI_BRUTE_FORCE_MAX / KAKAOCLI_BRUTE_FORCE_TIMEOUT.\n", stderr)
        }
        return found
    }

    private static func longestCommonSuffix(_ strings: [String]) -> String? {
        guard let first = strings.first else { return nil }
        let reversed = strings.map { String($0.reversed()) }
        var commonLen = 0
        for i in reversed[0].indices {
            let ch = reversed[0][i]
            if reversed.allSatisfy({ i < $0.endIndex && $0[i] == ch }) {
                commonLen += 1
            } else {
                break
            }
        }
        guard commonLen > 0 else { return nil }
        return String(first.suffix(commonLen))
    }
}

public enum KakaoError: Error, CustomStringConvertible {
    case uuidNotFound
    case plistNotFound(String)
    case plistParseError
    case userIdNotFound([String])
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case sqlError(String)
    case kakaoTalkNotInstalled
    case userIdResolution(String)

    public var description: String {
        switch self {
        case .uuidNotFound:
            return "Could not read IOPlatformUUID from ioreg"
        case .plistNotFound(let path):
            return "KakaoTalk preferences not found at \(path). Is KakaoTalk installed?"
        case .plistParseError:
            return "Failed to parse KakaoTalk preferences plist"
        case .userIdNotFound(let keys):
            return "Could not find user ID in plist. Available keys: \(keys.joined(separator: ", "))"
        case .databaseNotFound(let path):
            return "KakaoTalk database not found at \(path)"
        case .databaseOpenFailed(let msg):
            return "Failed to open database: \(msg)"
        case .sqlError(let msg):
            return "SQL error: \(msg)"
        case .kakaoTalkNotInstalled:
            return "KakaoTalk.app is not installed"
        case .userIdResolution(let msg):
            return msg
        }
    }
}
