import SwiftUI
import MotifKit

struct ClipCell: View {
    let item: ClipListItem
    let model: ProjectModel
    let hover: HoverPlayer
    let selected: Bool
    /// Called on any click, so the grid can take keyboard focus.
    var onActivate: () -> Void = {}

    @State private var poster: CGImage?
    @State private var sprite: CGImage?
    @State private var hoverFraction: CGFloat?
    @State private var hovering = false

    private var clip: ClipRecord { item.clip }
    private var aspect: CGFloat { clip.width > 0 && clip.height > 0 ? min(2.4, max(0.56, CGFloat(clip.width) / CGFloat(clip.height))) : 16 / 9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                Text(clip.name).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                descriptionText
                if clip.analysisState == .done { ChipRow(chips: clip.chips, stability: clip.stability.flatMap(Stability.init(rawValue:))) }
            }
            .padding(.horizontal, 2)
        }
        .padding(7)
        .background(selected ? Theme.accent.opacity(0.07) : hovering ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.55) : .clear, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        // The thumbnail has its own mouse handling (it is the drag handle); this covers the text below it.
        .onTapGesture { onActivate(); model.click(item.id, modifiers: NSEvent.modifierFlags) }
        .task(id: "\(clip.id ?? 0)-\(clip.analysisState.rawValue)") { await loadPoster() }
    }

    // MARK: thumbnail

    private var thumbnail: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        if let frame = hoverFrame ?? poster {
                            Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: aspect < 1.2 ? .fit : .fill)
                                .frame(width: geo.size.width, height: geo.size.height).clipped()
                        } else {
                            placeholder
                        }
                        if hover.activeID == item.id, hover.ready {
                            PlayerLayerView(player: hover.player).allowsHitTesting(false)
                        }
                    }
                    // Topmost layer of the thumbnail: owns clicks and drags, and — being topmost — is also where hover arrives.
                    .overlay {
                        dragSource.onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                hoverFraction = min(0.999, max(0, point.x / max(geo.size.width, 1)))
                                if clip.analysisState == .done || clip.analysisState == .pending || clip.analysisState == .running {
                                    hover.begin(id: item.id, url: model.sourceOnline ? model.project.fileURL(for: clip) : nil)
                                }
                                if sprite == nil { Task { await loadSprite() } }
                            case .ended:
                                hoverFraction = nil
                                hover.end(id: item.id)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: 1) }
            .overlay(alignment: .bottomTrailing) {
                if clip.duration > 0 {
                    Text(timecode(clip.duration)).font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                }
            }
            .overlay(alignment: .topLeading) { motionGlyph.padding(6) }
            .overlay(alignment: .topTrailing) { matchBadge.padding(6) }
            .overlay(alignment: .bottom) {
                // Scrub position while the filmstrip is showing (before playback starts, or with the drive offline).
                if let f = hoverFraction, !(hover.activeID == item.id && hover.ready), sprite != nil {
                    GeometryReader { geo in Theme.accent.frame(width: 2).offset(x: f * geo.size.width) }.frame(height: 3)
                }
            }
    }

    /// Click to select (⌘ / ⇧ for more), double-click to play, drag to take the original files to an editor's timeline or bin.
    private var dragSource: ClipDragSource {
        ClipDragSource(
            items: {
                model.dragFiles(startingAt: item.id).map { file in
                    let poster = ImageCache.shared.cachedPoster(at: model.project.posterURL(file.id), maxPixel: 640)
                    return (file.url, poster.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
                }
            },
            onClick: { count, modifiers in
                onActivate()
                switch count {
                case 0: model.press(item.id)
                case 2: model.click(item.id, modifiers: []); NotificationCenter.default.post(name: .togglePlayback, object: nil)
                default: model.click(item.id, modifiers: modifiers)
                }
            },
            menu: {
                model.press(item.id)
                let files = model.dragFiles(startingAt: item.id).map(\.url)
                let menu = NSMenu()
                menu.autoenablesItems = false
                let noun = files.count > 1 ? "\(files.count) Clips" : "Clip"
                menu.addItem(ActionMenuItem("Reveal \(noun) in Finder", enabled: !files.isEmpty) { NSWorkspace.shared.activateFileViewerSelecting(files) })
                menu.addItem(ActionMenuItem("Copy \(noun)", enabled: !files.isEmpty) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(files.map { $0 as NSURL })
                })
                menu.addItem(ActionMenuItem("Copy File Path\(files.count > 1 ? "s" : "")", enabled: !files.isEmpty) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
                })
                return menu
            })
    }

    /// The filmstrip tile under the pointer.
    private var hoverFrame: CGImage? {
        guard let f = hoverFraction, let sprite, let layout = clip.sprite else { return nil }
        let index = min(layout.tiles - 1, Int(f * CGFloat(layout.tiles)))
        let rect = CGRect(x: (index % layout.columns) * layout.tileWidth, y: (index / layout.columns) * layout.tileHeight,
                          width: layout.tileWidth, height: layout.tileHeight)
        return sprite.cropping(to: rect)
    }

    @ViewBuilder private var placeholder: some View {
        switch clip.analysisState {
        case .unsupported:
            VStack(spacing: 5) { Image(systemName: "questionmark.video"); Text("Unsupported").font(.caption2) }.foregroundStyle(Theme.textTertiary)
        case .failed:
            VStack(spacing: 5) { Image(systemName: "exclamationmark.triangle"); Text("Couldn't analyse").font(.caption2) }.foregroundStyle(Theme.textTertiary)
        default:
            if clip.missing { Image(systemName: "externaldrive.badge.xmark").foregroundStyle(Theme.textTertiary) }
            else { ProgressView().controlSize(.small).opacity(clip.analysisState == .running ? 1 : 0.35) }
        }
    }

    /// Where in the clip the searched-for move happens, when it isn't the whole clip.
    @ViewBuilder private var matchBadge: some View {
        if let range = model.hits[item.id]?.segmentRange, clip.duration > 0, range.upperBound - range.lowerBound < clip.duration * 0.9 {
            Label("\(timecode(range.lowerBound))–\(timecode(range.upperBound))", systemImage: "scope")
                .font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.accent.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder private var motionGlyph: some View {
        if clip.analysisState == .done, let chip = clip.chips.first {
            Image(systemName: chip.symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.62), in: Circle())
                .foregroundStyle(.white.opacity(chip.primitive == "static" ? 0.7 : 1))
        }
    }

    // MARK: text

    @ViewBuilder private var descriptionText: some View {
        if let tag = item.tag {
            Text(tag.description).font(.callout).foregroundStyle(Theme.textPrimary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } else {
            switch clip.describeState {
            case .failed: Text("Description failed").font(.callout).foregroundStyle(Theme.textTertiary)
            case .blocked: Text("Description blocked by the model's safety filter").font(.callout).foregroundStyle(Theme.textTertiary)
            case .skipped where clip.analysisState == .done: Text("On-device only").font(.callout).foregroundStyle(Theme.textTertiary)
            default:
                if clip.analysisState == .done && model.hasTagger { Text("Describing…").font(.callout).foregroundStyle(Theme.textTertiary) }
                else if let error = clip.error, clip.analysisState != .done { Text(error).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(2) }
            }
        }
    }

    // MARK: loading

    private func loadPoster() async {
        guard let id = clip.id, clip.analysisState == .done else { return }
        poster = await ImageCache.shared.poster(at: model.project.posterURL(id), maxPixel: 640)
    }

    private func loadSprite() async {
        guard let id = clip.id, clip.analysisState == .done else { return }
        sprite = await ImageCache.shared.sprite(at: model.project.spriteURL(id))
    }
}

struct ChipRow: View {
    let chips: [Chip]
    let stability: Stability?
    var wraps = false

    var body: some View {
        let views = Group {
            ForEach(chips, id: \.self) { ChipView(chip: $0) }
            if let stability { StabilityChip(stability: stability) }
        }
        if wraps { FlowLayout(spacing: 5) { views } }
        else { ViewThatFits(in: .horizontal) { HStack(spacing: 5) { views }; FlowLayout(spacing: 5) { views } } }
    }
}

struct ChipView: View {
    let chip: Chip

    var body: some View {
        // A Linear-style label: white pill, hairline border, colour only in the glyph.
        HStack(spacing: 4) {
            Image(systemName: chip.symbol).font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(chip.primitive == "static" ? Theme.textTertiary : Theme.accent)
            Text(chip.title).foregroundStyle(Theme.textPrimary.opacity(0.85))
            if let speed = chip.speed { Text(speed).foregroundStyle(Theme.textTertiary) }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
        .fixedSize()
    }
}

struct StabilityChip: View {
    let stability: Stability

    var body: some View {
        Text(stability.label).font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(Theme.textSecondary)
            .background(Theme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
            .fixedSize()
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
