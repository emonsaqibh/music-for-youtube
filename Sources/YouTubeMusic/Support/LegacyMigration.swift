import Foundation

/// Carries sign-in and settings over from the app's old bundle identifier.
///
/// Through 1.3.0 the app was `dev.fringecore.ytmusic` (`….dev` for the dev build). macOS keys
/// preferences, WebKit's website data and the cookie jar by bundle ID, so under the new ID
/// the app would start signed out with default settings. The first launch under the new ID
/// copies the old data across, once. The originals stay where they are: an older build
/// still finds them, and nothing is lost if a copy goes wrong.
enum LegacyMigration {
    private static let markerKey = "migratedFromLegacyBundleID"

    /// Must run before anything reads UserDefaults or opens a `WKWebsiteDataStore`: both
    /// hold on to what they find, so data copied in afterwards would be ignored or
    /// overwritten.
    static func run() {
        guard let newID = Bundle.main.bundleIdentifier else { return }
        let oldID = newID.replacingOccurrences(of: "emonsaqib", with: "fringecore")
        let defaults = UserDefaults.standard
        guard oldID != newID, defaults.object(forKey: markerKey) == nil else { return }
        var carried: [String] = []

        // Settings (including the remembered account and profile). Anything already set
        // under the new ID wins.
        if let old = defaults.persistentDomain(forName: oldID), !old.isEmpty {
            let current = defaults.persistentDomain(forName: newID) ?? [:]
            defaults.setPersistentDomain(old.merging(current) { _, new in new }, forName: newID)
            carried.append("\(old.count) settings")
        }

        // Sign-in: WebKit's website data (the account store and the guest store live under
        // WebKit/<id>) and the cookie jars. Caches are left behind; they refill.
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
        for (folder, suffix) in [("WebKit", ""), ("HTTPStorages", ""), ("HTTPStorages", ".binarycookies")] {
            let from = library.appending(path: "\(folder)/\(oldID)\(suffix)")
            let to = library.appending(path: "\(folder)/\(newID)\(suffix)")
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.copyItem(at: from, to: to)
                carried.append("\(folder)/\(oldID)\(suffix)")
            } catch {
                Log.write("legacy migration: couldn't copy \(from.path): \(error.localizedDescription)")
            }
        }

        defaults.set(oldID, forKey: markerKey)
        Log.write(carried.isEmpty
            ? "legacy migration: nothing to carry over from \(oldID)"
            : "legacy migration from \(oldID): \(carried.joined(separator: ", "))")
    }
}
