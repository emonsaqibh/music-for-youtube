import AppKit
import CoreImage
import SwiftUI

/// Memory + disk cache for artwork, plus the dominant-colour extraction the full-screen
/// player uses for its ambient glow.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, NSImage>()
    private let colors = NSCache<NSURL, NSColor>()
    private let ambients = NSCache<NSURL, NSImage>()
    private var palettes: [URL: [NSColor]] = [:]
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.countLimit = 400
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inflight[url] { return await running.value }

        let task = Task<NSImage?, Never> { [session] in
            guard let (data, _) = try? await session.data(from: url),
                  let image = NSImage(data: data) else { return nil }
            return image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Average colour of the artwork, saturated a little so it reads as a deliberate
    /// accent rather than mud.
    func accent(_ url: URL) async -> NSColor? {
        if let hit = colors.object(forKey: url as NSURL) { return hit }
        guard let image = await image(url),
              let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }

        let extent = ci.extent
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci,
                                                 kCIInputExtentKey: CIVector(cgRect: extent)]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: nil)

        let base = NSColor(srgbRed: CGFloat(pixel[0]) / 255,
                           green: CGFloat(pixel[1]) / 255,
                           blue: CGFloat(pixel[2]) / 255,
                           alpha: 1)
        guard let hsb = base.usingColorSpace(.deviceRGB) else { return base }
        let color = NSColor(hue: hsb.hueComponent,
                            saturation: min(1, hsb.saturationComponent * 1.45 + 0.08),
                            brightness: max(0.32, min(0.62, hsb.brightnessComponent)),
                            alpha: 1)
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
        guard let image = await image(url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

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

        guard let rendered = CIContext().createCGImage(output, from: bounds) else { return nil }
        let result = NSImage(cgImage: rendered, size: NSSize(width: side, height: side))
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
        guard let image = await image(url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

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
            let distinct = picked.allSatisfy { Self.distance($0, candidate.color) > 0.2 }
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

        let tuned = picked.map(Self.backgroundTone)
        palettes[url] = tuned
        if palettes.count > 200 { palettes.removeAll() }
        return tuned
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
struct Artwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var circular: Bool = false
    var symbol: String = "music.note"

    @State private var image: NSImage?

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
            .task(id: url) {
                image = url.flatMap { ImageCache.shared.cached($0) }
                guard image == nil, let url else { return }
                let loaded = await ImageCache.shared.image(url)
                withAnimation(.easeOut(duration: 0.22)) { image = loaded }
            }
    }
}
