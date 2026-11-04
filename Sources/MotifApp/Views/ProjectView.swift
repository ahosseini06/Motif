import SwiftUI
import MotifKit

struct ProjectView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: ProjectModel
    @State private var hover = HoverPlayer()
    @State private var showInspector = true
    @FocusState private var gridFocused: Bool

    var body: some View {
        Group {
            if model.designerOpen { ShotDesignerView(project: model, designer: model.designer) } else { browser }
        }
        .navigationTitle(model.project.name)
        .navigationSubtitle(model.designerOpen ? "Shot designer" : subtitle)
        .toolbar { toolbar }
        .onDisappear { hover.end() }
    }

    private var browser: some View {
        HSplitView {
            VStack(spacing: 0) {
                SearchBar(model: model)
                banners
                grid
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)

            if showInspector {
                InspectorView(model: model)
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)
                    .background(Theme.panel)
                    .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
            }
        }
    }

    private var subtitle: String {
        let n = model.counts.total
        let picked = model.selectedIDs.count > 1 ? " · \(model.selectedIDs.count) selected — drag them into your editor" : ""
        return n == 0 ? "No clips yet" : "\(n) clip\(n == 1 ? "" : "s")" + picked
    }

    // MARK: grid

    private var grid: some View {
        let clips = model.displayed
        return ScrollViewReader { proxy in
            ScrollView {
                if clips.isEmpty {
                    EmptyState(model: model).frame(maxWidth: .infinity).padding(.top, 120)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.cellWidth, maximum: model.cellWidth * 1.6), spacing: 14, alignment: .top)], spacing: 18) {
                        ForEach(clips) { item in
                            ClipCell(item: item, model: model, hover: hover, selected: model.selectedIDs.contains(item.id)) { gridFocused = true }
                                .id(item.id)
                                .onAppear { model.setVisible(item.id, true) }
                                .onDisappear { model.setVisible(item.id, false) }
                        }
                    }
                    .padding(18)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.leftArrow) { model.move(-1); return .handled }
            .onKeyPress(.rightArrow) { model.move(1); return .handled }
            .onKeyPress(.upArrow) { model.move(-columns); return .handled }
            .onKeyPress(.downArrow) { model.move(columns); return .handled }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAll(); return .handled
            }
            .onKeyPress(.space) { NotificationCenter.default.post(name: .togglePlayback, object: nil); return .handled }
            .onChange(of: model.selection) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
            .background(GeometryReader { geo in Color.clear.onAppear { gridWidth = geo.size.width }.onChange(of: geo.size.width) { _, w in gridWidth = w } })
        }
    }

    @State private var gridWidth: CGFloat = 900
    private var columns: Int { max(1, Int((gridWidth - 36 + 14) / (model.cellWidth + 14))) }

    // MARK: banners

    @ViewBuilder private var banners: some View {
        if !model.sourceOnline {
            Banner(icon: "externaldrive.badge.xmark", text: "The footage folder is offline. Thumbnails, filmstrips and tags still work; playback resumes when it's back.",
                   action: ("Check Again", { model.rescan() }))
        }
        if !app.hasAPIKey && !model.neverUpload && ProcessInfo.processInfo.environment["MOTIF_FAKE_TAGGER"] != "1" {
            Banner(icon: "key", text: "Camera movement is being measured on this Mac. Add your own Gemini API key to get descriptions — it's free to create and costs about $1 per 1,000 clips.",
                   settings: "Add Key…")
        } else if let issue = model.describeIssue {
            Banner(icon: "exclamationmark.triangle", text: "Descriptions are paused: \(issue)", settings: "Fix Key…")
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { if model.designerOpen { model.designerOpen = false } else { app.close() } } label: { Image(systemName: "chevron.left") }
                .help(model.designerOpen ? "Back to clips" : "Back to projects")
        }
        ToolbarItem(placement: .principal) { ProgressPill(model: model) }
        ToolbarItemGroup(placement: .primaryAction) {
          if !model.designerOpen {
            Slider(value: $model.cellWidth, in: 170...420).frame(width: 110).help("Thumbnail size")
            Menu {
                if model.isSearching { Text("Sorted by relevance while searching") }
                Picker("Sort by", selection: $model.sort) { ForEach(ClipSort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
            } label: { Image(systemName: "arrow.up.arrow.down") }.help("Sort")
            Menu {
                Button(model.paused ? "Resume Processing" : "Pause Processing") { model.paused.toggle() }
                Button("Rescan Folder & Retry Failed") { model.rescan() }
                Divider()
                Toggle("On-Device Only (never upload)", isOn: $model.neverUpload)
                Divider()
                Button("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.project.url]) }
            } label: { Image(systemName: "ellipsis.circle") }
            Button { withAnimation(.easeOut(duration: 0.18)) { showInspector.toggle() } } label: { Image(systemName: "sidebar.trailing") }.help("Inspector")
          }
        }
    }
}

extension Notification.Name {
    static let togglePlayback = Notification.Name("motif.togglePlayback")
}

private struct Banner: View {
    let icon: String, text: String
    var action: (String, () -> Void)?
    /// A title here opens Settings through SwiftUI's own link, which works whatever the private selector is called.
    var settings: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(text).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action { Button(action.0, action: action.1).controlSize(.small) }
            if let settings { SettingsLink { Text(settings) }.controlSize(.small) }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Theme.accent.opacity(0.06))
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

private struct EmptyState: View {
    let model: ProjectModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.isSearching ? "magnifyingglass" : "film.stack").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(model.isSearching ? "No clips match" : (model.status.isEmpty ? "No video files in this folder" : model.status))
                .foregroundStyle(Theme.textSecondary)
            if model.isSearching, !model.descriptionQuery.isEmpty, !model.hasDescriptions {
                Text("Description search needs descriptions — add a Gemini API key in Settings.").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            if !model.isSearching, let path = model.project.sourceURL?.path {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct ProgressPill: View {
    let model: ProjectModel
    @State private var showing = false

    var body: some View {
        let c = model.counts
        let analysing = c.analysed < c.total - failedAnalysis
        let describing = model.hasTagger && !model.neverUpload && model.describeIssue == nil && c.described < c.describable
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                if model.paused { Image(systemName: "pause.fill").font(.caption2) }
                else if analysing || describing || !model.status.isEmpty { ProgressView().controlSize(.mini) }
                else { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent) }
                Text(label(analysing: analysing, describing: describing)).font(.callout).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(Theme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) { detail.padding(16).frame(width: 300) }
    }

    private var failedAnalysis: Int { model.items.filter { $0.clip.analysisState == .failed }.count }

    private func label(analysing: Bool, describing: Bool) -> String {
        let c = model.counts
        if !model.status.isEmpty { return model.status }
        if model.paused { return "Paused" }
        if model.describeIssue != nil { return "Descriptions paused — check your key" }
        var parts: [String] = []
        if analysing { parts.append("Measuring motion \(c.analysed)/\(c.total)") }
        if describing { parts.append("Describing \(c.described)/\(c.describable)") }
        if parts.isEmpty { return c.total == 0 ? "Ready" : "Up to date" }
        return parts.joined(separator: " · ")
    }

    private var detail: some View {
        let c = model.counts
        let unsupported = model.items.filter { $0.clip.analysisState == .unsupported }.count
        let blocked = model.items.filter { $0.clip.describeState == .blocked }.count
        return VStack(alignment: .leading, spacing: 8) {
            row("Motion measured", "\(c.analysed) of \(c.total)")
            row("Described", model.neverUpload ? "off — on-device only" : "\(c.described) of \(c.describable)")
            if let issue = model.describeIssue {
                Text(issue).font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if c.failed > 0 { row("Failed", "\(c.failed)") }
            if blocked > 0 { row("Blocked by safety filter", "\(blocked)") }
            if unsupported > 0 { row("Unsupported files", "\(unsupported)") }
            if model.spend.tokensIn > 0 {
                Divider()
                row("API usage", "\(model.spend.tokensIn.formatted()) in · \(model.spend.tokensOut.formatted()) out")
                row("Approx. cost", String(format: "$%.4f", model.spendUSD))
            }
        }
        .font(.callout)
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a).foregroundStyle(Theme.textSecondary); Spacer(); Text(b).monospacedDigit() }
    }
}
