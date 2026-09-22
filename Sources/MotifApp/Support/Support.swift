import SwiftUI
import AVFoundation
import ImageIO
import MotifKit

enum Theme {
    // Light, quiet and dense, after Linear: near-white surfaces, hairline borders, one indigo accent,
    // and colour reserved for meaning (motion channels, selection).
    static let background = Color(red: 0.988, green: 0.988, blue: 0.992)
    static let panel = Color(red: 0.969, green: 0.969, blue: 0.975)
    static let surface = Color.white
    static let hover = Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.05)
    static let hairline = Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.10)
    static let accent = Color(red: 0.369, green: 0.416, blue: 0.824)   // #5E6AD2
    static let textPrimary = Color(red: 0.11, green: 0.114, blue: 0.122)
    static let textSecondary = Color(red: 0.42, green: 0.435, blue: 0.463)
    static let textTertiary = Color(red: 0.608, green: 0.62, blue: 0.643)

    /// One hue per motion channel, shared by chips' glyphs and the motion graph.
    static func colour(_ channel: MotionChannel) -> Color {
        switch channel {
        case .pan: return Color(red: 0.15, green: 0.47, blue: 0.90)
        case .tilt: return Color(red: 0.05, green: 0.58, blue: 0.55)
        case .roll: return Color(red: 0.49, green: 0.34, blue: 0.85)
        case .zoom: return Color(red: 0.87, green: 0.27, blue: 0.40)
        case .truck: return Color(red: 0.89, green: 0.49, blue: 0.10)
        case .pedestal: return Color(red: 0.72, green: 0.56, blue: 0.04)
        case .dolly: return Color(red: 0.25, green: 0.62, blue: 0.22)
        }
    }
}

extension Chip {
    var symbol: String {
        switch (primitive, direction) {
        case ("pan", "left"): return "arrow.left"
        case ("pan", _): return "arrow.right"
        case ("tilt", "up"): return "arrow.up"
        case ("tilt", _): return "arrow.down"
        case ("roll", "cw"): return "arrow.clockwise"
        case ("roll", _): return "arrow.counterclockwise"
        case ("zoom", "in"): return "plus.magnifyingglass"
        case ("zoom", _): return "minus.magnifyingglass"
        case ("dolly", "in"): return "arrow.down.right.and.arrow.up.left"
        case ("dolly", _): return "arrow.up.left.and.arrow.down.right"
        case ("truck", "left"): return "arrow.left.to.line"
        case ("truck", _): return "arrow.right.to.line"
        case ("pedestal", "up"): return "arrow.up.to.line"
        case ("pedestal", _): return "arrow.down.to.line"
        case ("arc", "left"): return "arrow.uturn.left"
        case ("arc", _): return "arrow.uturn.right"
        case ("crane", "up"): return "arrow.up.right"
        case ("crane", _): return "arrow.down.right"
        case ("dolly zoom", _): return "camera.metering.center.weighted"
        default: return "lock"
        }
    }
}

func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "–" }
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Decoded posters and filmstrips, bounded by cost so ten thousand clips can't take the app down.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let posters = NSCache<NSString, CGImage>()
    private let sprites = NSCache<NSString, CGImage>()

    private init() {
        posters.totalCostLimit = 220 << 20
        sprites.totalCostLimit = 260 << 20
    }

    /// Already-decoded poster, if the grid has shown it. For drag images, which can't wait.
    func cachedPoster(at url: URL, maxPixel: Int) -> CGImage? { posters.object(forKey: "\(url.path)@\(maxPixel)" as NSString) }

    func poster(at url: URL, maxPixel: Int) async -> CGImage? {
        let key = "\(url.path)@\(maxPixel)" as NSString
        if let hit = posters.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let image { posters.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    func sprite(at url: URL) async -> CGImage? {
        let key = url.path as NSString
        if let hit = sprites.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        if let image { sprites.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }
}

/// One muted player shared by the whole grid: whichever cell is hovered borrows it.
@MainActor @Observable
final class HoverPlayer {
    let player = AVPlayer()
    private(set) var activeID: Int64?
    private(set) var ready = false
    private var pending: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var loopObserver: NSObjectProtocol?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
    }

    func begin(id: Int64, url: URL?) {
        guard activeID != id else { return }
        end()
        activeID = id
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))           // dwell: skimming across cells shouldn't spin up decoders
            guard let self, !Task.isCancelled, self.activeID == id else { return }
            let item = AVPlayerItem(url: url)
            item.preferredPeakBitRate = 0
            self.statusObservation = item.observe(\.status) { [weak self] item, _ in
                Task { @MainActor in if item.status == .readyToPlay, self?.activeID == id { self?.ready = true } }
            }
            self.loopObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.player.seek(to: .zero); self?.player.play() }
            }
            self.player.replaceCurrentItem(with: item)
            self.player.play()
        }
    }

    func end(id: Int64? = nil) {
        if let id, id != activeID { return }
        pending?.cancel()
        statusObservation = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        activeID = nil
        ready = false
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = LayerHost()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? LayerHost)?.playerLayer.player = player
    }

    final class LayerHost: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}
