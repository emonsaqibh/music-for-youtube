import AppKit
import CoreImage
import ImageIO
import SwiftUI

/// Memory + disk cache for artwork, plus the dominant-colour extraction the full-screen
/// player uses for its ambient glow.
///
/// Nothing is decoded on the main thread. Artwork is downsampled to the size it is drawn
/// at (a 40pt row needs 80px, not YouTube's 544px) and fully decoded in the background,
/// so scrolling a shelf only composites bitmaps that are already ready.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    /// A decoded bitmap: the largest size asked for so far, or the source's own size.
    private final class Entry {
        let image: NSImage
        let pixels: Int
        let isFullSize: Bool

        init(image: NSImage, pixels: Int, isFullSize: Bool) {
            self.image = image
            self.pixels = pixels
            self.isFullSize = isFullSize
        }

        func covers(_ wanted: Int?) -> Bool {
            guard let wanted else { return isFullSize }
            return isFullSize || pixels >= wanted
        }
    }

    private let memory = NSCache<NSURL, Entry>()
    private let colors = NSCache<NSURL, NSColor>()
    private let ambients = NSCache<NSURL, NSImage>()
    private var palettes: [URL: [NSColor]] = [:]
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var downloads: [URL: Task<Data?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 192 << 20
        // Small entries, but one per song or page ever shown: bounded like the rest.
        colors.countLimit = 500
        ambients.countLimit = 100
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// The decoded sizes artwork is requested at, so a tile that grows by a point while the
    /// window resizes reuses what it has instead of decoding again.
    nonisolated static func pixelTier(for pixels: CGFloat) -> Int {
        guard pixels > 0 else { return 0 }
        for tier in [64, 128, 256, 384, 512, 768, 1024, 1536] where CGFloat(tier) >= pixels { return tier }
        return 2048
    }

    /// A decoded copy at least `pixels` wide, if one is in memory. `0` takes any size.
    func cached(_ url: URL, atLeast pixels: Int = 0) -> NSImage? {
        guard let entry = memory.object(forKey: url as NSURL), entry.covers(pixels) else { return nil }
        return entry.image
    }

    /// The artwork decoded to fit `pixels` on its longer side, or at its own size if nil.
    func image(_ url: URL, pixels: Int? = nil) async -> NSImage? {
        if let entry = memory.object(forKey: url as NSURL), entry.covers(pixels) { return entry.image }
        let key = "\(pixels ?? 0) \(url.absoluteString)"
        if let running = inflight[key] { return await running.value }

        let task = Task<NSImage?, Never> {
            guard let data = await self.data(url),
                  let cg = await Task.detached(priority: .userInitiated, operation: {
                      Pixels.decode(data, maxPixels: pixels)
                  }).value else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil

        if let image, let rep = image.representations.first {
            let side = max(rep.pixelsWide, rep.pixelsHigh)
            // Asked for more than the source has: this is as sharp as it gets.
            let full = pixels.map { side < $0 } ?? true
            let existing = memory.object(forKey: url as NSURL)
            if existing == nil || side > existing!.pixels || (full && !existing!.isFullSize) {
                memory.setObject(Entry(image: image, pixels: side, isFullSize: full),
                                 forKey: url as NSURL, cost: rep.pixelsWide * rep.pixelsHigh * 4)
            }
        }
        return image
    }

    /// The encoded bytes, shared by concurrent requests for the same URL. Repeat visits
    /// come from the disk cache.
    private func data(_ url: URL) async -> Data? {
        if let running = downloads[url] { return await running.value }
        let task = Task<Data?, Never> { [session] in
            try? await session.data(from: url).0
        }
        downloads[url] = task
        let data = await task.value
        downloads[url] = nil
        return data
    }

    /// Average colour of the artwork, saturated a little so it reads as a deliberate
    /// accent rather than mud.
    func accent(_ url: URL) async -> NSColor? {
        if let hit = colors.object(forKey: url as NSURL) { return hit }
        guard let data = await data(url),
              let color = await Task.detached(priority: .userInitiated, operation: {
                  Pixels.accent(data)
              }).value else { return nil }
        colors.setObject(color, forKey: url as NSURL)
        return color
    }
}

extension ImageCache {
    /// A tiny, heavily blurred and saturated copy of the artwork for the full-screen
    /// player's moving background.
    ///
    /// Blurring once here, at 64px, means the background can drift and rotate for free:
    /// SwiftUI only composites a pre-rendered bitmap instead of re-running a large blur
    /// every frame.
    func ambient(_ url: URL) async -> NSImage? {
        if let hit = ambients.object(forKey: url as NSURL) { return hit }
        guard let data = await data(url),
              let rendered = await Task.detached(priority: .userInitiated, operation: {
                  Pixels.ambient(data)
              }).value else { return nil }
        let result = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        ambients.setObject(result, forKey: url as NSURL)
        return result
    }
}

extension ImageCache {
    /// The artwork's main colours, most prominent first, tuned to sit behind white text —
    /// what Music.app's full-screen player builds its flowing background from.
    ///
    /// The image is reduced to 32×32 and its pixels bucketed by colour; buckets are ranked
    /// by size, nudged towards colourful ones so a small bright accent can beat a large
    /// dull area, and near-duplicates are skipped so the palette has range.
    func palette(_ url: URL) async -> [NSColor]? {
        if let hit = palettes[url] { return hit }
        guard let data = await data(url),
              let tuned = await Task.detached(priority: .userInitiated, operation: {
                  Pixels.palette(data)
              }).value else { return nil }
        palettes[url] = tuned
        if palettes.count > 200 { palettes.removeAll() }
        return tuned
    }
}

/// The pixel work behind `ImageCache`, kept off the main actor.
private enum Pixels {
    /// CIContexts are expensive to create and safe to share across threads.
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Decodes straight to the target size — ImageIO reads only what it needs from the
    /// JPEG — and forces the decode now, on this thread, rather than at first draw.
    static func decode(_ data: Data, maxPixels: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixels { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func accent(_ data: Data) -> NSColor? {
        guard let cg = decode(data, maxPixels: 64) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci,
                                                 kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)

        let base = NSColor(srgbRed: CGFloat(pixel[0]) / 255,
                           green: CGFloat(pixel[1]) / 255,
                           blue: CGFloat(pixel[2]) / 255,
                           alpha: 1)
        guard let hsb = base.usingColorSpace(.deviceRGB) else { return base }
        return NSColor(hue: hsb.hueComponent,
                       saturation: min(1, hsb.saturationComponent * 1.45 + 0.08),
                       brightness: max(0.32, min(0.62, hsb.brightnessComponent)),
                       alpha: 1)
    }

    static func ambient(_ data: Data) -> CGImage? {
        guard let cg = decode(data, maxPixels: 128) else { return nil }

        let side: CGFloat = 64
        let input = CIImage(cgImage: cg)
        let scale = side / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)

        let output = small
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 7)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.5,
                kCIInputBrightnessKey: -0.06,
            ])
            .cropped(to: bounds)

        return context.createCGImage(output, from: bounds)
    }

    /// See `ImageCache.palette`.
    static func palette(_ data: Data) -> [NSColor]? {
        guard let cg = decode(data, maxPixels: 64) else { return nil }

        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        struct Bucket { var count = 0; var r = 0.0, g = 0.0, b = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            buckets[key, default: Bucket()].count += 1
            buckets[key]!.r += Double(r) / 255
            buckets[key]!.g += Double(g) / 255
            buckets[key]!.b += Double(b) / 255
        }

        let ranked = buckets.values.map { bucket -> (color: NSColor, score: Double) in
            let n = Double(bucket.count)
            let color = NSColor(srgbRed: bucket.r / n, green: bucket.g / n, blue: bucket.b / n, alpha: 1)
            return (color, n * (0.35 + color.saturationComponent))
        }
        .sorted { $0.score > $1.score }

        var picked: [NSColor] = []
        for candidate in ranked where picked.count < 5 {
            let distinct = picked.allSatisfy { distance($0, candidate.color) > 0.2 }
            if distinct { picked.append(candidate.color) }
        }
        guard let first = picked.first else { return nil }
        // Single-colour artwork: vary the one colour rather than showing a flat field.
        while picked.count < 3 {
            let shift = CGFloat(picked.count) * 0.04
            picked.append(NSColor(hue: (first.hueComponent + shift).truncatingRemainder(dividingBy: 1),
                                  saturation: first.saturationComponent,
                                  brightness: first.brightnessComponent * (picked.count == 1 ? 0.65 : 1.2),
                                  alpha: 1))
        }

        return picked.map(backgroundTone)
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> Double {
        let dr = a.redComponent - b.redComponent
        let dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent - b.blueComponent
        return Double((dr * dr + dg * dg + db * db).squareRoot())
    }

    /// Richer and never too bright: colours stay recognisably the artwork's, but white
    /// lyrics over them stay readable. Only real colours are enriched — a faintly tinted
    /// grey (silver, cream) stays near-grey rather than turning into a colour the artwork
    /// doesn't have.
    private static func backgroundTone(_ color: NSColor) -> NSColor {
        let s = color.saturationComponent, b = color.brightnessComponent
        if s < 0.25 {
            return NSColor(hue: color.hueComponent, saturation: s * 0.8,
                           brightness: min(max(b, 0.16), 0.46), alpha: 1)
        }
        return NSColor(hue: color.hueComponent,
                       saturation: min(0.92, s * 1.15),
                       brightness: min(max(b, 0.3), 0.72),
                       alpha: 1)
    }
}

/// Artwork with a graceful placeholder and a cross-fade once the image lands.
///
/// It measures itself and asks for a bitmap of that size, so a 40pt row decodes 80px
/// rather than YouTube's 544px. Anything already in memory is shown on the very first
/// frame — scrolling back to a row never flashes the placeholder.
struct Artwork: View {
    let url: URL?
    var cornerRadius: CGFloat
    var circular: Bool
    var symbol: String

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    /// The decode size this view needs, from its laid-out size. 0 until measured.
    @State private var pixels = 0
    /// What `image` currently is, so a view that has what it needs doesn't reload.
    @State private var loaded: Loaded?

    private struct Loaded: Equatable {
        let url: URL
        let pixels: Int
    }

    private struct Request: Equatable {
        let url: URL?
        let pixels: Int
    }

    init(url: URL?, cornerRadius: CGFloat = 8, circular: Bool = false, symbol: String = "music.note") {
        self.url = url
        self.cornerRadius = cornerRadius
        self.circular = circular
        self.symbol = symbol
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0) })
    }

    private var shape: AnyShape {
        circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    var body: some View {
        shape
            .fill(Theme.artworkPlaceholder)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(shape)
            // Reported as a size tier, so resizing the window only re-renders a tile when
            // it crosses into a size that needs a sharper bitmap.
            .onGeometryChange(for: Int.self) { [displayScale] proxy in
                ImageCache.pixelTier(for: max(proxy.size.width, proxy.size.height) * displayScale)
            } action: { pixels = $0 }
            .task(id: Request(url: url, pixels: pixels)) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            loaded = nil
            return
        }
        if let loaded, loaded.url == url, loaded.pixels >= pixels { return }

        let cache = ImageCache.shared
        if let hit = cache.cached(url, atLeast: pixels) {
            image = hit
            loaded = Loaded(url: url, pixels: pixels)
            return
        }
        // A new URL: show a smaller copy while the right size decodes, else the placeholder.
        if loaded?.url != url {
            image = cache.cached(url)
            loaded = nil
        }
        guard pixels > 0 else { return }

        guard let fetched = await cache.image(url, pixels: pixels), !Task.isCancelled else { return }
        if image == nil {
            withAnimation(.easeOut(duration: 0.22)) { image = fetched }
        } else {
            image = fetched
        }
        loaded = Loaded(url: url, pixels: pixels)
    }
}
