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
