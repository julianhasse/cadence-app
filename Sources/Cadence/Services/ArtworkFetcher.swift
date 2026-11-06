import AppKit
import CoreImage

/// Downloads artwork from a direct URL (Spotify) or looks it up via the public iTunes Search API.
enum ArtworkFetcher {
    @MainActor private static let cache = NSCache<NSString, NSImage>()

    @MainActor
    static func fetch(for track: Track) async -> NSImage? {
        let key = "\(track.artist)|\(track.album.isEmpty ? track.title : track.album)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var url = track.artworkURL
        if url == nil { url = await searchITunes(track) }
        guard let url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func searchITunes(_ track: Track) async -> URL? {
        guard !track.artist.isEmpty else { return nil }
        let byAlbum = !track.album.isEmpty
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track.artist) \(byAlbum ? track.album : track.title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: byAlbum ? "album" : "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let art = first["artworkUrl100"] as? String else { return nil }
        return URL(string: art.replacingOccurrences(of: "100x100", with: "600x600"))
    }
}

extension NSImage {
    /// Average colour of the image, used to tint the player from the artwork.
    var averageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension NSColor {
    /// Keeps artwork-derived tints readable on dark backgrounds.
    var tintAdjusted: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, max(s, 0.35)), brightness: max(b, 0.75), alpha: 1)
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FF2D55" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
