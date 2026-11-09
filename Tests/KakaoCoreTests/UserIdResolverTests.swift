import CommonCrypto
import Foundation
import Testing
@testable import KakaoCore

private func sha512Hex(_ s: String) -> String {
    let data = Array(s.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
    CC_SHA512(data, CC_LONG(data.count), &hash)
    return hash.map { String(format: "%02x", $0) }.joined()
}

/// Real Keychain item under a throwaway service, so tests never touch the user's cache.
private func testCache() -> UserIdCache {
    UserIdCache(service: "com.kakaocli.cache.tests.\(UUID().uuidString)")
}

// MARK: - Parallel brute force

@Test func bruteForceFindsSyntheticId() {
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: sha512Hex("123457"), maxId: 2_000_000, progress: false) == 123457)
    // Exactly on a 1M-chunk boundary, and the smallest id.
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: sha512Hex("1048576"), maxId: 3_000_000, progress: false) == 1_048_576)
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: sha512Hex("1"), maxId: 10, progress: false) == 1)
}

@Test func bruteForceRespectsBoundAndTimeout() {
    // Outside the bound: nil.
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: sha512Hex("5000"), maxId: 5000, progress: false) == nil)
    // Unfindable hash with a huge bound: stops at the timeout instead of scanning.
    let start = Date()
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: sha512Hex("not-a-number"), maxId: 1 << 50, timeout: 0.3, progress: false) == nil)
    #expect(Date().timeIntervalSince(start) < 5)
    // Malformed hash.
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: "abc", maxId: 10, progress: false) == nil)
}

@Test func userIdMatchesHash() {
    #expect(DeviceInfo.userId(42, matchesHash: sha512Hex("42")))
    #expect(!DeviceInfo.userId(43, matchesHash: sha512Hex("42")))
}

// MARK: - Env override

@Test func envOverrideParsing() throws {
    #expect(try DeviceInfo.userIdOverride(environment: [:]) == nil)
    #expect(try DeviceInfo.userIdOverride(environment: ["KAKAOCLI_USER_ID": " 777 "]) == 777)
    #expect(throws: KakaoError.self) { try DeviceInfo.userIdOverride(environment: ["KAKAOCLI_USER_ID": "abc"]) }
    #expect(throws: KakaoError.self) { try DeviceInfo.userIdOverride(environment: ["KAKAOCLI_USER_ID": "-1"]) }
}

@Test func envOverrideWinsAndIsAuthoritative() throws {
    let cache = testCache()
    defer { cache.clear() }
    cache.write(111)

    let id = try UserIdResolver.resolve(
        environment: ["KAKAOCLI_USER_ID": "777"], cache: cache, activeHash: { nil },
        detect: { Issue.record("detect must not run"); return 1 }, candidates: { [] },
        opens: { $0 == 777 })
    #expect(id == 777)
    #expect(cache.read() == 111, "env override must not rewrite the cache")

    // A wrong override fails loudly instead of silently falling back.
    #expect(throws: KakaoError.self) {
        try UserIdResolver.resolve(
            environment: ["KAKAOCLI_USER_ID": "778"], cache: nil, activeHash: { nil },
            detect: { 777 }, candidates: { [] }, opens: { $0 == 777 })
    }
}

// MARK: - Cache

@Test func cacheReadWriteClear() {
    let cache = testCache()
    defer { cache.clear() }
    #expect(cache.read() == nil)
    cache.write(424_242)
    #expect(cache.read() == 424_242)
    cache.write(7)  // overwrite (-U)
    #expect(cache.read() == 7)
    cache.clear()
    #expect(cache.read() == nil)
}

@Test func validCacheSkipsDetection() throws {
    let cache = testCache()
    defer { cache.clear() }
    cache.write(222)
    let id = try UserIdResolver.resolve(
        environment: [:], cache: cache, activeHash: { sha512Hex("222") },
        detect: { Issue.record("detect must not run on a cache hit"); return 1 }, candidates: { [] },
        opens: { $0 == 222 })
    #expect(id == 222)
}

@Test func cacheThatNoLongerOpensIsReplaced() throws {
    let cache = testCache()
    defer { cache.clear() }
    cache.write(111)  // stale: DB was re-keyed / reinstalled
    var opened: [Int] = []
    let id = try UserIdResolver.resolve(
        environment: [:], cache: cache, activeHash: { nil },
        detect: { 222 }, candidates: { [111, 333] },
        opens: { opened.append($0); return $0 == 222 })
    #expect(id == 222)
    #expect(opened == [111, 222], "stale id tried once, not retried as a candidate")
    #expect(cache.read() == 222)
}

@Test func cacheForOtherAccountIsInvalidatedByHash() throws {
    let cache = testCache()
    defer { cache.clear() }
    cache.write(111)  // previous account; its DB file would still open
    let id = try UserIdResolver.resolve(
        environment: [:], cache: cache, activeHash: { sha512Hex("333") },
        detect: { 333 }, candidates: { [] },
        opens: { _ in true })
    #expect(id == 333)
    #expect(cache.read() == 333)
}

@Test func nothingOpensThrowsAndLeavesCacheEmpty() {
    let cache = testCache()
    defer { cache.clear() }
    #expect(throws: KakaoError.self) {
        try UserIdResolver.resolve(
            environment: [:], cache: cache, activeHash: { nil },
            detect: { throw KakaoError.userIdNotFound([]) }, candidates: { [1, 2] },
            opens: { _ in false })
    }
    #expect(cache.read() == nil)
}
