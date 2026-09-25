import SwiftUI

enum Theme {
    /// The accent chosen in Settings — Music.app's red unless changed. Read inside a view
    /// body, so every view that uses it redraws when the choice changes.
    @MainActor static var accent: Color { AppSettings.shared.accent.color }

    static let artworkPlaceholder = Color.primary.opacity(0.08)

    /// Measured against Music.app: 32pt gutters, 34pt large titles, and enough room at
    /// the bottom of every scroll view for content to clear the floating player.
    static let pageInset: CGFloat = 32
    static let contentTop: CGFloat = 26
    static let playerClearance: CGFloat = 104

    static let tileWidth: CGFloat = 156
    static let tileCorner: CGFloat = 10
    static let shelfGap: CGFloat = 36

    static let sidebarWidth: CGFloat = 220
    static let sidebarMinWidth: CGFloat = 200
}

extension View {
    func pageInsets() -> some View { padding(.horizontal, Theme.pageInset) }

    /// Standard chrome for a scrolling page: large title spacing at the top, and room
    /// under the floating player at the bottom.
    func pageScroll() -> some View {
        scrollIndicators(.visible)
            .scrollContentBackground(.hidden)
    }
}

/// The 34pt bold heading every page opens with.
struct PageTitle: View {
    let text: String
    /// A small capsule after the title, e.g. "DEV · 1.3.1-dev.14" on the dev build's Home.
    var badge: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text)
                .font(.system(size: 34, weight: .bold))
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.4)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(BuildFlavor.devColor, in: Capsule())
            }
        }
        .pageInsets()
        .padding(.top, Theme.contentTop)
        .padding(.bottom, 6)
    }
}

/// A shelf heading. Apple Music makes the whole thing a button with a trailing chevron
/// when there is more to see, rather than a separate "See All" link.
struct SectionHeader: View {
    let title: String
    var strapline: String?
    var onSeeAll: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                if let strapline, !strapline.isEmpty {
                    Text(strapline.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                    if onSeeAll != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0.55)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSeeAll?() }
    }
}

/// The Play / Shuffle buttons under a page header.
struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 84)
                .frame(height: 30)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
    }
}

/// Circular play button revealed on hover over a tile.
struct HoverPlayButton: View {
    var isVisible: Bool
    var symbol: String = "play.fill"
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.4), in: Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.pressable(scale: 0.86))
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.85)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isVisible)
    }
}

/// Bare icon button used throughout the player chrome — no background until hovered.
struct TransportButton: View {
    let symbol: String
    var size: CGFloat = 14
    var isEnabled: Bool = true
    var isActive: Bool = false
    var weight: Font.Weight = .medium
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(isActive ? Theme.accent : Color.primary.opacity(0.85))
                .frame(width: size * 2, height: size * 2)
                .contentShape(Rectangle())
                .background {
                    if hovering && isEnabled { Circle().fill(.primary.opacity(0.1)) }
                }
        }
        .buttonStyle(.pressable(scale: 0.86))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .onHover { hovering = $0 }
    }
}

/// Rounded rectangular button group that floats over content — the shape Apple Music
/// uses for the close / volume / lyrics clusters in the full-screen player.
struct GlassCluster<Content: View>: View {
    var spacing: CGFloat = 2
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Motion

/// How things move: springs rather than timed curves, so motion carries momentum and
/// settles the way iOS does. Kept to transforms and opacity — cheap for the GPU.
enum Motion {
    /// Selections, reorders, content swaps.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.82)
    /// Presses: a quick squeeze with a little give on release.
    static let bouncy = Animation.spring(response: 0.26, dampingFraction: 0.6)
    /// Larger surfaces arriving (pages, shelves).
    static let gentle = Animation.spring(response: 0.45, dampingFraction: 0.88)
    /// The pill stretching into the full-screen player and back: slower than the rest and
    /// a little underdamped, so the shape overshoots and settles like the Dynamic Island.
    static let expand = Animation.spring(response: 0.52, dampingFraction: 0.8)
}

/// Squeezes a button while it's held and springs it back on release.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.bouncy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    static func pressable(scale: CGFloat) -> PressableButtonStyle { PressableButtonStyle(scale: scale) }
}

/// Floats a view in — up a few points and from transparent — shortly after it appears,
/// later for later items, so a page's first sections arrive one after another. Only the
/// first few are staggered; the rest appear as they are.
private struct AppearIn: ViewModifier {
    let order: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        if order > 5 {
            content
        } else {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 14)
                .onAppear {
                    guard !shown else { return }
                    withAnimation(Motion.gentle.delay(Double(order) * 0.05)) { shown = true }
                }
        }
    }
}

extension View {
    func appearIn(order: Int) -> some View { modifier(AppearIn(order: order)) }
}
