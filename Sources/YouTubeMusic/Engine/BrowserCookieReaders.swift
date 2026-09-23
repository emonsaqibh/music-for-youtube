import CommonCrypto
import Foundation
import Security
import SQLite3
import WebKit

// Readers that lift the YouTube/Google session cookies out of a browser's on-disk store.
//
// See BrowserImport.swift for why this exists and the distribution caveats. Every reader is
// scoped to the caller's wanted domains and skips everything else.

// MARK: - Safari

/// Safari keeps cookies in a documented "binarycookies" file. No decryption; the file itself
/// is protected by macOS (TCC), so the app needs Full Disk Access to read it.
enum SafariCookies {
    /// Candidate locations across macOS versions (sandboxed container first on modern macOS).
    private static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "\(home)/Library/Cookies/Cookies.binarycookies",
        ]
    }

    static func read(domains: [String]) throws -> [HTTPCookie] {
        guard let path = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let data = FileManager.default.contents(atPath: path)
        else { throw BrowserImport.ImportError.notReadable(.safari) }
        return parse(data).filter { cookie in domains.contains { cookie.domain.hasSuffix($0) || $0.hasSuffix(cookie.domain) } }
    }

    /// Parses the binarycookies container. Format is big-endian for the outer structure and
    /// little-endian inside each page; times are seconds since the 2001 Mac epoch.
    private static func parse(_ data: Data) -> [HTTPCookie] {
        var cookies: [HTTPCookie] = []
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0] == 0x63, bytes[1] == 0x6F, bytes[2] == 0x6F, bytes[3] == 0x6B
        else { return [] }  // "cook"

        func u32be(_ o: Int) -> Int { Int(bytes[o]) << 24 | Int(bytes[o+1]) << 16 | Int(bytes[o+2]) << 8 | Int(bytes[o+3]) }
        func u32le(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o+1]) << 8 | Int(bytes[o+2]) << 16 | Int(bytes[o+3]) << 24 }
        func f64le(_ o: Int) -> Double {
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(bytes[o+i]) << (8*i) }
            return Double(bitPattern: raw)
        }
        func cstr(_ o: Int) -> String {
            var end = o
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            return String(decoding: bytes[o..<end], as: UTF8.self)
        }

        let pageCount = u32be(4)
        var pageSizes: [Int] = []
        var cursor = 8
        for _ in 0..<pageCount { pageSizes.append(u32be(cursor)); cursor += 4 }

        var pageStart = cursor
        for size in pageSizes {
            let page = pageStart
            let numCookies = u32le(page + 4)
            for i in 0..<numCookies {
                let cookieOffset = page + u32le(page + 8 + i*4)
                let flags = u32le(cookieOffset + 8)
                let urlOff   = cookieOffset + u32le(cookieOffset + 16)
                let nameOff  = cookieOffset + u32le(cookieOffset + 20)
                let pathOff  = cookieOffset + u32le(cookieOffset + 24)
                let valueOff = cookieOffset + u32le(cookieOffset + 28)
                let expiry = f64le(cookieOffset + 40)

                let domain = cstr(urlOff)
                let name   = cstr(nameOff)
                let path   = cstr(pathOff)
                let value  = cstr(valueOff)
                guard !name.isEmpty, !domain.isEmpty else { continue }

                var props: [HTTPCookiePropertyKey: Any] = [
                    .domain: domain, .path: path.isEmpty ? "/" : path,
                    .name: name, .value: value,
                    .expires: Date(timeIntervalSinceReferenceDate: expiry),
                ]
                if flags & 1 != 0 { props[.secure] = "TRUE" }
                if flags & 4 != 0 { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let cookie = HTTPCookie(properties: props) { cookies.append(cookie) }
            }
            pageStart += size
        }
        return cookies
    }
}

// MARK: - Chromium (Chrome / Brave / Edge / Arc / Vivaldi / Opera)

/// Chromium browsers keep cookies in an SQLite database whose values are AES-encrypted with a
/// key stored in the login Keychain under "<Browser> Safe Storage". Reading them means asking
/// the Keychain for that key — macOS shows the user a permission prompt the first time, which
/// is why `unlock(_:)` is a separate, explicit step — and decrypting each value.
enum ChromiumCookies {
    struct Layout {
        /// Under ~/Library/Application Support.
        let dataDirectory: String
        let keychainService: String
        /// Opera keeps its one profile at the top of its data directory.
        var flatProfile = false
    }

    static func layout(_ browser: BrowserImport.Browser) -> Layout? {
        switch browser {
        case .chrome:  Layout(dataDirectory: "Google/Chrome", keychainService: "Chrome Safe Storage")
        case .brave:   Layout(dataDirectory: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage")
        case .edge:    Layout(dataDirectory: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage")
        case .arc:     Layout(dataDirectory: "Arc/User Data", keychainService: "Arc Safe Storage")
        case .vivaldi: Layout(dataDirectory: "Vivaldi", keychainService: "Vivaldi Safe Storage")
        case .opera:   Layout(dataDirectory: "com.operasoftware.Opera", keychainService: "Opera Safe Storage", flatProfile: true)
        case .safari, .firefox: nil
        }
    }

    // MARK: Key

    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: [BrowserImport.Browser: Data] = [:]

    static func isUnlocked(_ browser: BrowserImport.Browser) -> Bool {
        lock.withLock { keys[browser] != nil }
    }

    /// Fetches the browser's cookie key from the Keychain — this is what raises the macOS
    /// "wants to use your confidential information" prompt — and derives the AES key from
    /// it. Blocks while the prompt is up, so call it off the main thread.
    static func unlock(_ browser: BrowserImport.Browser) throws {
        guard let layout = layout(browser) else { throw BrowserImport.ImportError.notImplemented(browser) }
        if isUnlocked(browser) { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: layout.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            Log.write("chromium-keychain: \(layout.keychainService) → \(status) \(SecCopyErrorMessageString(status, nil) as String? ?? "")")
            throw status == errSecItemNotFound
                ? BrowserImport.ImportError.notReadable(browser)
                : BrowserImport.ImportError.keychainDenied(browser)
        }
        // Chromium on macOS: PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 128-bit key.
        var derived = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let result = derived.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { sl in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         sl.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard result == kCCSuccess else { throw BrowserImport.ImportError.keychainDenied(browser) }
        lock.withLock { keys[browser] = derived }
    }

    // MARK: Reading

    /// The cookies of the browser profile that is signed in to YouTube — the most recently
    /// used profile first — or the last-used profile's (without a session) if none is.
    static func read(browser: BrowserImport.Browser, domains: [String]) throws -> [HTTPCookie] {
        guard let layout = layout(browser) else { throw BrowserImport.ImportError.notImplemented(browser) }
        guard let key = lock.withLock({ keys[browser] }) else { throw BrowserImport.ImportError.keychainDenied(browser) }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(layout.dataDirectory)", directoryHint: .isDirectory)

        var fallback: [HTTPCookie] = []
        for profile in profiles(root: root, flat: layout.flatProfile) {
            let candidates = [profile.appending(path: "Cookies"), profile.appending(path: "Network/Cookies")]
            guard let db = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            let cookies = try readDatabase(db, key: key, domains: domains)
            if cookies.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) { return cookies }
            if fallback.isEmpty { fallback = cookies }
        }
        return fallback
    }

    /// Profile folders, the last-used one (from "Local State") first.
    private static func profiles(root: URL, flat: Bool) -> [URL] {
        if flat { return [root] }
        var names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted()
        if let data = FileManager.default.contents(atPath: root.appending(path: "Local State").path),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lastUsed = (state["profile"] as? [String: Any])?["last_used"] as? String,
           let index = names.firstIndex(of: lastUsed) {
            names.insert(names.remove(at: index), at: 0)
        }
        return names.map { root.appending(path: $0, directoryHint: .isDirectory) }
    }

    private static func readDatabase(_ url: URL, key: Data, domains: [String]) throws -> [HTTPCookie] {
        try SQLiteCopy.withCopy(of: url) { db in
            // From schema version 24 the plaintext starts with SHA-256(host), to be skipped.
            let version = Int(SQLiteCopy.rows(db, "SELECT value FROM meta WHERE key = 'version'").first?[0].text ?? "") ?? 0
            let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies"
            var cookies: [HTTPCookie] = []
            for row in SQLiteCopy.rows(db, sql) {
                let host = row[0].text ?? ""
                guard domains.contains(where: { host.hasSuffix($0) }) else { continue }
                let plain = row[2].text ?? ""
                guard let value = plain.isEmpty ? decrypt(row[3].blob, key: key, stripHash: version >= 24) : plain
                else { continue }
                var props: [HTTPCookiePropertyKey: Any] = [
                    .domain: host, .path: row[4].text ?? "/", .name: row[1].text ?? "", .value: value,
                ]
                // Microseconds since 1601; 0 means a session cookie.
                let expires = row[5].int
                if expires > 0 {
                    props[.expires] = Date(timeIntervalSince1970: Double(expires) / 1_000_000 - 11_644_473_600)
                }
                if row[6].int != 0 { props[.secure] = "TRUE" }
                if row[7].int != 0 { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                switch row[8].int {
                case 1: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
                case 2: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
                default: break
                }
                if let cookie = HTTPCookie(properties: props) { cookies.append(cookie) }
            }
            return cookies
        }
    }

    /// "v10" + AES-128-CBC (IV of 16 spaces, PKCS#7).
    private static func decrypt(_ blob: Data, key: Data, stripHash: Bool) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let payload = Data(blob.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        var outLength = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { o in
            payload.withUnsafeBytes { p in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                p.baseAddress, payload.count, o.baseAddress, outCapacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plain = out.prefix(outLength)
        if stripHash, plain.count >= 32 { plain = plain.dropFirst(32) }
        return String(data: plain, encoding: .utf8)
    }
}

// MARK: - Firefox

/// Firefox keeps cookies unencrypted in each profile's cookies.sqlite, so there is no key and
/// no prompt. The profile whose cookie store changed most recently is tried first.
enum FirefoxCookies {
    static func read(domains: [String]) throws -> [HTTPCookie] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Firefox/Profiles", directoryHint: .isDirectory)
        let stores = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: "cookies.sqlite") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { modified($0) > modified($1) }
        guard !stores.isEmpty else { throw BrowserImport.ImportError.notReadable(.firefox) }

        var fallback: [HTTPCookie] = []
        for store in stores {
            let cookies = try SQLiteCopy.withCopy(of: store) { db in
                SQLiteCopy.rows(db, "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies")
                    .compactMap { row -> HTTPCookie? in
                        let host = row[0].text ?? ""
                        guard domains.contains(where: { host.hasSuffix($0) }) else { return nil }
                        var props: [HTTPCookiePropertyKey: Any] = [
                            .domain: host, .name: row[1].text ?? "", .value: row[2].text ?? "",
                            .path: row[3].text ?? "/",
                        ]
                        // Seconds since 1970 (newer Firefox versions store milliseconds).
                        let expiry = Double(row[4].int)
                        if expiry > 0 { props[.expires] = Date(timeIntervalSince1970: expiry > 1e11 ? expiry / 1000 : expiry) }
                        if row[5].int != 0 { props[.secure] = "TRUE" }
                        if row[6].int != 0 { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                        switch row[7].int {
                        case 1: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
                        case 2: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
                        default: break
                        }
                        return HTTPCookie(properties: props)
                    }
            }
            if cookies.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) { return cookies }
            if fallback.isEmpty { fallback = cookies }
        }
        return fallback
    }

    private static func modified(_ url: URL) -> Date {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let dates = [url, wal].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return dates.max() ?? .distantPast
    }
}

// MARK: - SQLite

/// Browsers keep their cookie databases open (and locked) while running, so each read works
/// on a private copy — the database plus its -journal/-wal/-shm siblings — in a temp folder.
enum SQLiteCopy {
    struct Value {
        let text: String?
        let blob: Data
        let int: Int64
    }

    static func withCopy<T>(of url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "cookie-read-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: url.lastPathComponent)
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    static func rows(_ db: OpaquePointer, _ sql: String) -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[Value]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = sqlite3_column_count(statement)
            result.append((0..<columns).map { i in
                let text = sqlite3_column_text(statement, i).map { String(cString: $0) }
                let bytes = sqlite3_column_bytes(statement, i)
                let blob = sqlite3_column_blob(statement, i).map { Data(bytes: $0, count: Int(bytes)) } ?? Data()
                return Value(text: text, blob: blob, int: sqlite3_column_int64(statement, i))
            })
        }
        return result
    }
}
