import Foundation
import WebKit

// Readers that lift the YouTube/Google session cookies out of a browser's on-disk store.
//
// See BrowserImport.swift for why this exists and the distribution caveats. Both readers are
// scoped to the caller's wanted domains and skip everything else.

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
/// the Keychain for that key (macOS shows the user a permission prompt the first time) and
/// decrypting each value.
enum ChromiumCookies {
    static func read(browser: BrowserImport.Browser, domains: [String]) throws -> [HTTPCookie] {
        throw BrowserImport.ImportError.notImplemented(browser)
    }
}
