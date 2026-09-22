import SwiftUI
import MotifKit

/// Two questions, asked separately: what is in the shot, and what the camera does. The movement side can be typed
/// ("slow push in, handheld"), picked from presets, or both — it all becomes one motion-vector query.
struct SearchBar: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                SearchField(icon: "text.magnifyingglass", prompt: "Describe the shot — “woman in a red coat, rainy street”", text: $model.descriptionQuery)
                SearchField(icon: "move.3d", prompt: "Camera movement — “slow push in, handheld”", text: $model.movementText)
                shotControl
                if model.isSearching {
                    Text("\(model.ranked.count) result\(model.ranked.count == 1 ? "" : "s")").font(.caption).monospacedDigit().foregroundStyle(Theme.textSecondary).fixedSize()
                    Button("Clear") { model.clearSearch() }.buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            FlowLayout(spacing: 5) {
                        ForEach(MovementQuery.movePresets, id: \.self) { move in
                            PresetChip(title: move.title, symbol: move.symbol, selected: model.presetMoves.contains(move)) { model.toggle(move) }
                        }
                        PresetChip(title: "static", symbol: "lock", selected: model.presetStatic) { model.toggleStatic() }
                        separator
                        ForEach(MovementQuery.speedPresets, id: \.self) { speed in
                            PresetChip(title: speed, selected: model.presetSpeed == speed) { model.presetSpeed = model.presetSpeed == speed ? nil : speed }
                        }
                        separator
                        ForEach([Stability.lockedOff, .stabilised, .handheld], id: \.self) { stability in
                            PresetChip(title: stability.label, selected: model.presetStability == stability) {
                                model.presetStability = model.presetStability == stability ? nil : stability
                            }
                        }
                        separator
                        ForEach(MovementQuery.relationPresets, id: \.self) { relation in
                            PresetChip(title: relation, selected: model.presetRelations.contains(relation)) {
                                if model.presetRelations.contains(relation) { model.presetRelations.remove(relation) } else { model.presetRelations.insert(relation) }
                            }
                            .help("How the move relates to the subject — judged by the description model")
                        }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    /// Search by a drawn camera move: open the designer, or reuse a saved shot.
    @ViewBuilder private var shotControl: some View {
        if let shot = model.activeShot {
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder").font(.system(size: 11, weight: .semibold))
                Text(shot.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(String(format: "%.0f s", shot.duration)).font(.caption).foregroundStyle(Theme.accent.opacity(0.7))
                Button { model.editActiveShot() } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit this shot")
                Button { model.clearShot() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Stop searching by this shot")
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1) }
            .fixedSize()
        } else {
            Menu {
                Button("Design a Shot…") { model.designerOpen = true }
                let saved = ShotLibrary.all()
                if !saved.isEmpty {
                    Section("Search by a saved shot") {
                        ForEach(saved) { shot in Button(shot.name) { model.searchBySavedShot(shot) } }
                    }
                }
            } label: {
                Label("Design a Shot", systemImage: "camera.viewfinder").font(.callout.weight(.medium))
            } primaryAction: { model.designerOpen = true }
            .menuStyle(.button).fixedSize()
            .help("Keyframe a 3D camera move and find the shots that move like it")
        }
    }

    private var separator: some View { Theme.hairline.frame(width: 1, height: 14).padding(.horizontal, 4) }
}

private struct SearchField: View {
    let icon: String, prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(focused ? Theme.accent : Theme.textTertiary).frame(width: 16)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain).font(.callout).foregroundStyle(Theme.textPrimary).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1) }
    }
}

private struct PresetChip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
                Text(title)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            .background(selected ? Theme.accent.opacity(0.10) : hovering ? Theme.hover : Theme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize()
    }
}
