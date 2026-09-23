import SwiftUI

/// A shelf of buttons to other pages. Explore sends two kinds: a few destinations with an
/// icon (New releases, Charts, Moods & genres) and the coloured mood and genre tiles.
struct ButtonShelf: View {
    let shelf: Shelf
    /// Mood tiles stack two to a column and page sideways.
    var rows = 2

    @Environment(Router.self) private var router

    private struct Column: Identifiable {
        let buttons: [NavButton]
        var id: String { buttons.first?.id ?? "" }
    }

    private var columns: [Column] {
        stride(from: 0, to: shelf.buttons.count, by: rows).map { start in
            Column(buttons: Array(shelf.buttons[start..<min(start + rows, shelf.buttons.count)]))
        }
    }

    var body: some View {
        if !shelf.buttons.contains(where: { $0.color != nil }) {
            // A handful of destinations share the row evenly.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14),
                                     count: min(max(shelf.buttons.count, 1), 4)),
                      spacing: 14) {
                ForEach(shelf.buttons) { button in
                    DestinationTile(button: button) { open(button) }
                }
            }
            .pageInsets()
        } else if shelf.isGrid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                ForEach(shelf.buttons) { button in
                    MoodTile(button: button) { open(button) }
                }
            }
            .pageInsets()
        } else {
            PagedShelf(items: columns, minItemWidth: 190, spacing: 16) { column in
                VStack(spacing: 16) {
                    ForEach(column.buttons) { button in
                        MoodTile(button: button) { open(button) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func open(_ button: NavButton) {
        router.open(.seeAll(browseId: button.browseId, params: button.params, title: button.title))
    }
}

/// One of Explore's top destinations: an icon, the title and a chevron.
private struct DestinationTile: View {
    let button: NavButton
    let action: () -> Void

    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: button.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                Text(button.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 60)
            .background(shape.fill(Color.primary.opacity(hovering ? 0.09 : 0.055)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A mood or genre, as Music.app draws its categories: a vivid gradient tile with the
/// name set large in white. The colour is YouTube's own for that mood.
private struct MoodTile: View {
    let button: NavButton
    let action: () -> Void

    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        Button(action: action) {
            MoodBackground(palette: MoodPalette(argb: button.color))
                .overlay(alignment: .bottomLeading) {
                    Text(button.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                .frame(height: 96)
                .clipShape(shape)
                // A hairline of light around the edge, as on Liquid Glass surfaces.
                .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(hovering ? 0.24 : 0.1),
                        radius: hovering ? 12 : 5, y: hovering ? 6 : 2)
                .scaleEffect(hovering ? 1.02 : 1)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25), value: hovering)
        .help(button.title)
    }
}

/// Shades around one hue, bright top-leading to deep bottom-trailing.
private struct MoodPalette {
    var light, base, deep, darkest: Color

    init(argb: UInt32?) {
        var hue: CGFloat = 0.62, saturation: CGFloat = 0, brightness: CGFloat = 0.5
        if let argb {
            NSColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
                    green: CGFloat((argb >> 8) & 0xFF) / 255,
                    blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        }
        let s: CGFloat, b: CGFloat
        if saturation < 0.12 {
            // YouTube's greys become graphite, keeping their relative lightness.
            hue = 0.62
            s = 0.12
            b = min(max(brightness * 0.6, 0.3), 0.5)
        } else {
            // Lift pastels to full colour and hold everything dark enough for white text.
            // Yellow can't be darkened without turning olive, so it leans to amber instead.
            if hue > 0.1 && hue < 0.2 { hue *= 0.6; saturation = max(saturation, 0.8) }
            s = min(max(saturation, 0.6), 0.88)
            b = min(max(brightness, 0.6), 0.84)
        }
        func shade(_ dh: CGFloat, _ ds: CGFloat, _ db: CGFloat) -> Color {
            Color(hue: (hue + dh + 1).truncatingRemainder(dividingBy: 1),
                  saturation: min(max(s * ds, 0), 1),
                  brightness: min(max(b * db, 0), 1))
        }
        // Deeper shades drift along the hue wheel for richness — towards red for warm
        // colours, since a darkened orange reads as brown.
        let drift: CGFloat = s > 0.2 && hue < 0.17 ? -1 : 1
        light = shade(-0.03 * drift, 0.8, 1.16)
        base = shade(0, 1, 1)
        deep = shade(0.03 * drift, 1.1, 0.8)
        darkest = shade(0.05 * drift, 1.15, 0.62)
    }
}

private struct MoodBackground: View {
    let palette: MoodPalette

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0],
                     [0, 0.5], [0.6, 0.4], [1, 0.5],
                     [0, 1], [0.5, 1], [1, 1]],
            colors: [palette.light, palette.base, palette.deep,
                     palette.base, palette.base, palette.deep,
                     palette.deep, palette.deep, palette.darkest])
            // A soft highlight off the top edge gives the tile some depth.
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.white.opacity(0.22))
                    .frame(width: 110, height: 110)
                    .blur(radius: 30)
                    .offset(x: 20, y: -45)
            }
    }
}

extension NavButton {
    /// YouTube's icon types for Explore's destinations, as SF Symbols.
    var symbol: String {
        switch iconType {
        case "MUSIC_NEW_RELEASE": "sparkles"
        case "TRENDING_UP": "chart.line.uptrend.xyaxis"
        case "STICKER_EMOTICON": "face.smiling"
        default: "square.grid.2x2"
        }
    }
}

extension Color {
    /// From a packed ARGB integer, as YouTube sends colours.
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}
