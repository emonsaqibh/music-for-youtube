import SwiftUI

/// The round identity badge: the account's photo, its initial if there is no photo, or
/// the guest glyph.
struct AccountAvatar: View {
    let profile: Session.Profile
    var size: CGFloat = 28

    private var session: Session { .shared }

    var body: some View {
        Group {
            switch profile {
            case .guest:
                Circle()
                    .fill(Color.primary.opacity(0.1))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.46, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.25),
                                              style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                    }
            case .account:
                if let photo = session.account?.photo {
                    Artwork(url: photo, circular: true, symbol: "person.fill")
                } else if let initial = session.account?.name.first {
                    Circle()
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.accent],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay {
                            Text(String(initial).uppercased())
                                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

extension Session {
    /// How each profile is labelled in the UI.
    func title(for profile: Profile) -> String {
        switch profile {
        case .account: account?.name ?? "YouTube Music Account"
        case .guest: "Guest"
        }
    }

    func subtitle(for profile: Profile) -> String {
        switch profile {
        case .account:
            if let handle = account?.handle, !handle.isEmpty { return handle }
            if self.profile == .account { return isSignedIn ? "Signed in" : "Not signed in" }
            return hasAccount ? "Signed in" : "Sign in to use your library"
        case .guest:
            return "Listen without an account"
        }
    }
}

/// The account affordance pinned to the bottom of the sidebar. Clicking it opens the
/// profile switcher.
struct AccountRow: View {
    @State private var hovering = false
    @State private var showingSwitcher = false

    private var session: Session { .shared }

    var body: some View {
        HStack(spacing: 10) {
            AccountAvatar(profile: session.profile, size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(rowSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering || showingSwitcher ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering || showingSwitcher ? 0.07 : 0))
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { showingSwitcher.toggle() }
        .popover(isPresented: $showingSwitcher, arrowEdge: .trailing) {
            AccountSwitcher { showingSwitcher = false }
                .frame(width: 300)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Switch between your account and guest mode")
        .padding(.bottom, 12)
    }

    /// A remembered account counts as signed in until the page says otherwise, so the row
    /// doesn't flash "Sign In" during launch.
    private var signedIn: Bool { session.isSignedIn || session.hasAccount }

    private var rowTitle: String {
        if session.isGuest { return "Guest" }
        return signedIn ? session.title(for: .account) : "Account"
    }

    private var rowSubtitle: String {
        if session.isGuest { return "Guest mode" }
        return signedIn ? (session.account?.handle ?? "Signed in") : "Sign In"
    }
}

/// Both profiles, the active one ticked, plus sign-in / sign-out. Shared by the sidebar
/// popover and the Account settings pane.
struct AccountSwitcher: View {
    /// Off inside Settings itself.
    var showsSettingsLink = true
    var onDone: () -> Void = {}

    @Environment(\.openSettings) private var openSettings
    @State private var confirmingSignOut = false

    private var session: Session { .shared }
    /// The page may not have reported its state yet (just after launch or a switch); a
    /// remembered account is only forgotten by an explicit sign-out, so trust it.
    private var accountSignedIn: Bool { session.isSignedIn || session.hasAccount }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Listening as")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)

            profileRow(.account)
            profileRow(.guest)

            Divider().padding(.vertical, 4)

            if accountSignedIn {
                actionRow("Sign Out of YouTube Music", symbol: "rectangle.portrait.and.arrow.right",
                          destructive: true) {
                    confirmingSignOut = true
                }
            } else {
                actionRow("Sign In to YouTube Music…", symbol: "person.crop.circle.badge.plus") {
                    onDone()
                    SignIn.start()
                }
            }
            if showsSettingsLink {
                actionRow("Settings…", symbol: "gearshape") {
                    onDone()
                    openSettings()
                }
            }
        }
        .padding(8)
        .confirmationDialog("Sign out of YouTube Music?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                onDone()
                Task { await WebEngine.shared.signOut() }
            }
        } message: {
            Text("Your guest profile is kept. You can sign back in at any time.")
        }
    }

    private func profileRow(_ profile: Session.Profile) -> some View {
        let active = session.profile == profile
        return Button {
            guard !active else { return }
            if profile == .account && !session.hasAccount {
                // Nothing to switch to yet — signing in lands in the account profile.
                onDone()
                SignIn.start()
                return
            }
            onDone()
            PlayerController.shared.switchProfile(to: profile)
        } label: {
            HStack(spacing: 10) {
                AccountAvatar(profile: profile, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title(for: profile))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(session.subtitle(for: profile))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle(isSelected: active))
    }

    private func actionRow(_ title: String, symbol: String, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// A plain row button that highlights on hover and press, like a menu item.
struct HoverRowStyle: ButtonStyle {
    var isSelected = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12
                                                : hovering ? 0.07
                                                : isSelected ? 0.045 : 0))
            }
            .onHover { hovering = $0 }
    }
}
