import Foundation
import Observation
import WebKit

/// Which identity the engine is using, and who that is.
///
/// The app keeps two completely separate cookie stores: the **account** store (WebKit's
/// default store, where Google sign-in lands) and a **guest** store. Switching between
/// them never signs anyone out — the account session stays on disk while the guest one is
/// in use, and the other way round.
@MainActor
@Observable
final class Session {
    static let shared = Session()

    enum Profile: String, CaseIterable, Identifiable, Codable {
        case account, guest
        var id: String { rawValue }
    }

    /// The profile the engine is running under.
    private(set) var profile: Profile

    /// Whether the page the engine has loaded is signed in.
    private(set) var isSignedIn = false

    /// The signed-in account, remembered so it can be shown (and switched back to) while
    /// in guest mode.
    private(set) var account: AccountInfo?

    /// Bumped on every profile switch or sign-in change. Views that show account-specific
    /// content key their identity on it, so they reload rather than showing the other
    /// profile's data.
    private(set) var generation = 0

    private init() {
        profile = Profile(rawValue: UserDefaults.standard.string(forKey: Keys.profile) ?? "") ?? .account
        if let data = UserDefaults.standard.data(forKey: Keys.account) {
            account = try? JSONDecoder().decode(AccountInfo.self, from: data)
        }
    }

    var isGuest: Bool { profile == .guest }

    /// A remembered account exists to switch back to.
    var hasAccount: Bool { account != nil }

    // MARK: Updates from the engine

    func setProfile(_ profile: Profile) {
        self.profile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: Keys.profile)
        isSignedIn = false
        generation += 1
    }

    func pageReported(signedIn: Bool) {
        guard signedIn != isSignedIn else { return }
        isSignedIn = signedIn
        generation += 1
        // A page reporting "signed out" does not forget the account: that can happen
        // transiently mid-navigation. Only an explicit sign-out does.
    }

    func remember(_ info: AccountInfo) {
        account = info
        if let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: Keys.account)
        }
    }

    func forgetAccount() {
        account = nil
        UserDefaults.standard.removeObject(forKey: Keys.account)
    }

    // MARK: Stores

    /// Fixed so the guest store is the same one across launches.
    private static let guestStoreID = UUID(uuidString: "6C1F3B7E-5A2D-4C8B-9E0F-3D7A1B2C4E5F")!

    func dataStore(for profile: Profile) -> WKWebsiteDataStore {
        switch profile {
        case .account: .default()
        case .guest: WKWebsiteDataStore(forIdentifier: Self.guestStoreID)
        }
    }

    private enum Keys {
        static let profile = "session.profile"
        static let account = "session.account"
    }
}

/// The signed-in account as YouTube describes it in the account menu.
struct AccountInfo: Codable, Hashable, Sendable {
    var name: String
    var handle: String?
    var photo: URL?
}
