import SwiftUI

/// A horizontal row that always shows a whole number of items, sized to the window, and
/// pages by that many — Music.app's shelves. Items never end half-cut at the edge; there
/// are hover arrows at either end instead.
struct PagedShelf<Item: Identifiable, Content: View>: View where Item.ID: Hashable {
    let items: [Item]
    /// The narrowest an item may get before one fewer fits on a page.
    var minItemWidth: CGFloat
    var spacing: CGFloat = 20
    /// Leading and trailing inset of the first and last item.
    var margin: CGFloat = Theme.pageInset
    @ViewBuilder var content: (Item) -> Content

    @State private var leadingID: Item.ID?
    @State private var perPage = 1
    @State private var hovering = false

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(items) { item in
                    content(item)
                        .containerRelativeFrame(.horizontal) { length, _ in itemWidth(in: length) }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $leadingID, anchor: .leading)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            perPage = Self.count(in: width - margin * 2, minimum: minItemWidth, spacing: spacing)
        }
        // The neighbouring page shows in the margins; fade it rather than cutting it off.
        .mask(edgeFade)
        .overlay(alignment: .leading) { arrow(forward: false) }
        .overlay(alignment: .trailing) { arrow(forward: true) }
        .onHover { hovering = $0 }
    }

    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: margin)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: margin)
        }
    }

    static func count(in width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimum + spacing)))
    }

    private func itemWidth(in length: CGFloat) -> CGFloat {
        let n = CGFloat(Self.count(in: length, minimum: minItemWidth, spacing: spacing))
        return max(1, (length - spacing * (n - 1)) / n)
    }

    private var leadingIndex: Int {
        leadingID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }

    private func canPage(forward: Bool) -> Bool {
        forward ? leadingIndex + perPage < items.count : leadingIndex > 0
    }

    private func page(forward: Bool) {
        let target = forward
            ? min(leadingIndex + perPage, max(0, items.count - perPage))
            : max(0, leadingIndex - perPage)
        guard items.indices.contains(target) else { return }
        withAnimation(.smooth(duration: 0.45)) { leadingID = items[target].id }
    }

    private func arrow(forward: Bool) -> some View {
        Button { page(forward: forward) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .padding(.horizontal, 3)
        .opacity(hovering && canPage(forward: forward) ? 1 : 0)
        .allowsHitTesting(hovering && canPage(forward: forward))
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}
