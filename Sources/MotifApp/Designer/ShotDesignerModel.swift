import SwiftUI
import MotifKit

/// State of the shot designer: the shot being drawn, the playhead, and what the shot currently reads as.
@MainActor @Observable
final class ShotDesignerModel {
    let stageController = ShotStageController()

    private(set) var shot = DesignedShot()
    private(set) var time: Double = 0
    private(set) var pose = CameraPose()
    private(set) var isPlaying = false
    /// Any change to the camera writes a keyframe at the playhead — the Blender habit, and why there is no "apply" step.
    var autoKey = true
    /// Camera moved with auto-key off and not yet keyed.
    private(set) var hasUnkeyedChange = false

    private(set) var saved: [DesignedShot] = ShotLibrary.all()
    private(set) var isSaved = false

    // What the drawn move reads as, in the same terms as analysed footage.
    private(set) var tracks: [MotionTrack] = []
    private(set) var chips: [[Chip]] = []
    private(set) var samples: [MotionSample] = []

    private var playback: Task<Void, Never>?
    private var derive: Task<Void, Never>?
    private var undoStack: [DesignedShot] = []

    init() { refresh(rebuildPath: true) }

    var currentKeyframe: CameraKeyframe? { shot.keyframe(near: time) }
    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: time

    func seek(_ t: Double, snapping: Bool = false) {
        var next = max(0, min(shot.duration, t))
        if snapping, let key = shot.keyframes.min(by: { abs($0.time - next) < abs($1.time - next) }), abs(key.time - next) < shot.duration * 0.012 { next = key.time }
        time = next
        hasUnkeyedChange = false
        refresh(rebuildPath: true, rederive: false)
    }

    func jumpToKeyframe(_ direction: Int) {
        let times = shot.keyframes.map(\.time)
        if direction > 0, let next = times.first(where: { $0 > time + 0.01 }) { seek(next) }
        else if direction < 0, let previous = times.last(where: { $0 < time - 0.01 }) { seek(previous) }
        else { seek(direction > 0 ? shot.duration : 0) }
    }

    func togglePlayback() {
        if isPlaying { stop(); return }
        isPlaying = true
        if time >= shot.duration - 0.01 { time = 0 }
        playback = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.isPlaying else { return }
                let now = Date()
                var t = self.time + now.timeIntervalSince(last)
                last = now
                if t >= self.shot.duration { t = 0 }                      // loop: a move is judged by watching it repeat
                self.time = t
                self.hasUnkeyedChange = false
                self.refresh(rebuildPath: false, rederive: false)
            }
        }
    }

    func stop() { isPlaying = false; playback?.cancel(); playback = nil }

    // MARK: editing the camera

    /// Every control funnels through here: mutate the pose, and (with auto-key) that is the keyframe at the playhead.
    func edit(_ change: (inout CameraPose) -> Void) {
        stop()
        var next = pose
        change(&next)
        next.pitch = max(-89, min(89, next.pitch)); next.focal = max(12, min(250, next.focal)); next.position.y = max(0.15, next.position.y)
        guard next != pose else { return }
        if autoKey {
            checkpoint(coalescing: true)
            shot.setKeyframe(at: time, pose: next)
            isSaved = false
            refresh(rebuildPath: true)
        } else {
            pose = next
            hasUnkeyedChange = true
            stageController.apply(next)
        }
    }

    func setKeyframe() {
        checkpoint()
        shot.setKeyframe(at: time, pose: pose)
        hasUnkeyedChange = false; isSaved = false
        refresh(rebuildPath: true)
    }

    func deleteCurrentKeyframe() {
        guard let key = currentKeyframe, shot.keyframes.count > 1 else { return }
        checkpoint()
        shot.removeKeyframe(key.id); isSaved = false
        refresh(rebuildPath: true)
    }

    func retime(_ id: UUID, to t: Double) {
        checkpoint(coalescing: true)
        shot.retime(id, to: t); isSaved = false
        if let key = shot.keyframes.first(where: { $0.id == id }) { time = key.time }
        refresh(rebuildPath: true)
    }

    func setDuration(_ seconds: Double) {
        checkpoint()
        let fraction = shot.duration > 0 ? time / shot.duration : 0
        shot.setDuration(seconds); isSaved = false
        time = fraction * shot.duration
        refresh(rebuildPath: true)
    }

    func setEased(_ eased: Bool) { checkpoint(); shot.eased = eased; isSaved = false; refresh(rebuildPath: true) }
    func rename(_ name: String) { shot.name = name; isSaved = false }

    func apply(_ template: ShotTemplate) {
        checkpoint()
        shot.keyframes = template.keyframes(duration: shot.duration)
        if shot.name == "Untitled shot" || ShotTemplate.allCases.contains(where: { $0.rawValue == shot.name }) { shot.name = template.rawValue }
        isSaved = false
        time = 0
        refresh(rebuildPath: true)
    }

    // MARK: undo

    private var lastCheckpoint = Date.distantPast

    /// Snapshot before a change. A drag fires hundreds of edits; those within half a second share one undo step.
    private func checkpoint(coalescing: Bool = false) {
        let now = Date()
        if coalescing, now.timeIntervalSince(lastCheckpoint) < 0.5 { lastCheckpoint = now; return }
        lastCheckpoint = now
        undoStack.append(shot)
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        shot = previous; isSaved = false
        time = min(time, shot.duration)
        refresh(rebuildPath: true)
    }

    // MARK: library

    func newShot() { stop(); undoStack = []; shot = DesignedShot(); time = 0; isSaved = false; refresh(rebuildPath: true) }

    func load(_ saved: DesignedShot) { stop(); undoStack = []; shot = saved; time = 0; isSaved = true; refresh(rebuildPath: true) }

    func save() {
        shot.modifiedAt = Date()
        try? ShotLibrary.save(shot)
        saved = ShotLibrary.all()
        isSaved = true
    }

    func delete(_ target: DesignedShot) {
        ShotLibrary.delete(target)
        saved = ShotLibrary.all()
        if target.id == shot.id { isSaved = false }
    }

    /// The shot as a search query, derived now rather than from the debounced preview.
    func makeQuery() -> ShotQuery {
        ShotQuery(samples: shot.samples(depthAt: shot.depthProfile(on: stageController.stage)), duration: shot.duration)
    }

    static func query(for shot: DesignedShot) -> ShotQuery {
        let stage = ReferenceStage()
        return ShotQuery(samples: shot.samples(depthAt: shot.depthProfile(on: stage)), duration: shot.duration)
    }

    // MARK: derived state

    private func refresh(rebuildPath: Bool, rederive: Bool = true) {
        pose = shot.pose(at: time)
        stageController.apply(pose)
        if rebuildPath { stageController.rebuildPath(for: shot, currentTime: time) }
        guard rederive else { return }
        derive?.cancel()
        derive = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))                 // ray-casting the set on every mouse event would stutter the drag
            guard let self, !Task.isCancelled else { return }
            let samples = self.shot.samples(depthAt: self.shot.depthProfile(on: self.stageController.stage))
            let segments = Segmenter.segments(from: samples, clipDuration: self.shot.duration)
            self.samples = samples
            self.tracks = segments.map { MotionTrack(start: $0.start, end: $0.end, rows: $0.trajectory) }
            self.chips = segments.map(\.chips)
        }
    }
}
