import SwiftUI
import AVKit
import MotifKit

@MainActor @Observable
final class InspectorPlayer {
    let player = AVPlayer()
    private(set) var time: Double = 0
    var loop: ClosedRange<Double>? { didSet { if let loop { seek(loop.lowerBound); player.play() } } }
    private var observer: Any?
    private var loadedURL: URL?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                if let loop = self.loop, t.seconds >= loop.upperBound || t.seconds < loop.lowerBound - 0.3 { self.seek(loop.lowerBound) }
            }
        }
    }

    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        loadedURL = url
        loop = nil
        time = 0
        player.replaceCurrentItem(with: url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? AVPlayerItem(url: $0) : nil })
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle() {
        guard player.currentItem != nil else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

struct InspectorView: View {
    let model: ProjectModel
    @State private var player = InspectorPlayer()
    @State private var segments: [SegmentRecord] = []
    @State private var poster: CGImage?

    var body: some View {
        Group {
            if let item = model.selected { content(item) } else { empty }
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in player.toggle() }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.and.hand.point.up.left").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text("Select a clip").foregroundStyle(Theme.textSecondary)
            Text("Hover to play · click for details · space to play").font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ item: ClipListItem) -> some View {
        let clip = item.clip
        let online = model.sourceOnline && !clip.missing
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Color.black
                    if online { PlayerView(player: player.player) }
                    else if let poster {
                        Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        Label("Footage offline", systemImage: "externaldrive.badge.xmark").font(.caption)
                            .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.7), in: Capsule())
                    }
                }
                .aspectRatio(clip.width > 0 ? max(1.0, CGFloat(clip.width) / CGFloat(max(clip.height, 1))) : 16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(clip.name).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(2).textSelection(.enabled)
                    if let tag = item.tag, let size = tag.shotSize {
                        Text([size, tag.subjectRelation.flatMap { $0 == "none" ? nil : $0 }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                }

                section("Description") {
                    if let tag = item.tag { Text(tag.description).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    else { Text(pendingDescription(clip)).foregroundStyle(Theme.textTertiary) }
                }

                section("Camera movement") {
                    if let tag = item.tag { Text(tag.movementText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if clip.analysisState == .done {
                        ChipRow(chips: clip.chips, stability: clip.stability.flatMap(Stability.init(rawValue:)), wraps: true)
                    } else if let error = clip.error {
                        Text(error).font(.callout).foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Measuring…").foregroundStyle(Theme.textTertiary)
                    }
                }

                if !segments.isEmpty {
                    section("Motion") {
                        MotionGraph(tracks: segments.map { MotionTrack(start: $0.tStart, end: $0.tEnd, rows: $0.trajectoryRows) }, duration: clip.duration, time: player.time, loop: player.loop) { player.loop = nil; player.seek($0) }
                            .frame(height: 210)
                        VStack(spacing: 2) {
                            ForEach(segments) { segment in
                                SegmentRow(segment: segment, active: player.loop == segment.tStart...segment.tEnd) {
                                    player.loop = player.loop == segment.tStart...segment.tEnd ? nil : segment.tStart...segment.tEnd
                                }
                            }
                        }
                    }
                }

                section("File") { FileFacts(clip: clip, model: model) }
            }
            .padding(16)
        }
        .task(id: item.id) {
            player.load(online ? model.project.fileURL(for: clip) : nil)
            // Arriving from a movement search: go straight to the part of the clip that matched.
            if online, let range = model.hits[item.id]?.segmentRange, range.upperBound - range.lowerBound < clip.duration * 0.9 { player.loop = range }
            poster = clip.id == nil ? nil : await ImageCache.shared.poster(at: model.project.posterURL(clip.id!), maxPixel: 1280)
        }
        .task(id: "\(item.id)-\(clip.analysisState.rawValue)") { segments = model.project.segments(for: item.id) }
    }

    private func pendingDescription(_ clip: ClipRecord) -> String {
        switch clip.describeState {
        case .blocked: return "The model's safety filter declined to describe this clip."
        case .failed: return clip.error ?? "Description failed."
        case .skipped: return clip.analysisState == .done ? "On-device only — this project never uploads." : "—"
        default: return model.hasTagger ? "Describing…" : "Add a Gemini API key in Settings to describe clips."
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SegmentRow: View {
    let segment: SegmentRecord
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(timecodeFine(segment.tStart)) – \(timecodeFine(segment.tEnd))").font(.caption).monospacedDigit()
                    .foregroundStyle(active ? Theme.accent : Theme.textSecondary).frame(width: 96, alignment: .leading)
                Text(segment.chips.map(\.display).joined(separator: "  +  ")).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: active ? "repeat.circle.fill" : "repeat").font(.caption).foregroundStyle(active ? Theme.accent : Theme.textTertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(active ? Theme.accent.opacity(0.08) : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Loop this segment")
    }

    private func timecodeFine(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
}

private struct FileFacts: View {
    let clip: ClipRecord
    let model: ProjectModel

    var body: some View {
        let facts: [(String, String)] = [
            ("Duration", clip.duration > 0 ? String(format: "%@  (%.1f s)", timecode(clip.duration), clip.duration) : "–"),
            ("Format", clip.width > 0 ? "\(clip.width) × \(clip.height) · \(String(format: "%.3g", clip.fps)) fps · \(clip.codec)" : "–"),
            ("Transfer", clip.transferFunction ?? "untagged"),
            ("Camera", [clip.cameraMake, clip.cameraModel].compactMap { $0 }.joined(separator: " ")),
            ("Lens", clip.focal35mm.map { String(format: "%.0f mm (35 mm equiv.)", $0) } ?? ""),
            ("Shot", clip.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""),
            ("Size", ByteCountFormatter.string(fromByteCount: clip.size, countStyle: .file)),
            ("Audio", clip.hasAudio ? "yes" : "none"),
        ].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(facts, id: \.0) { fact in
                    GridRow {
                        Text(fact.0).foregroundStyle(Theme.textTertiary)
                        Text(fact.1).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
            Text(clip.relPath).font(.caption).foregroundStyle(Theme.textTertiary).textSelection(.enabled).lineLimit(3)
            Button("Reveal in Finder") {
                if let url = model.project.fileURL(for: clip) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .controlSize(.small)
            .disabled(!model.sourceOnline || clip.missing)
        }
    }
}
