// EditorHistory.swift
// Fantasia
// Plan 13-21 F8: the Editor's undo/redo engine — built LAST, on top of every other stabilized
// mutation path in this batch (F1-F7/F9-F17), per the plan's explicit ordering: undo/redo has to
// record against the FINAL shape of every mutation call site, not one that's about to change out
// from under it.
//
// Session-only (dies with the editor — no persistence across app relaunches, out of scope per the
// plan). Held on EditorState (`state.history`) rather than threaded as a separate param through
// every view's init — every view that already receives `state: EditorState` (all of them) gets
// history for free, matching how `state.pxPerSecond`/`state.isZooming` (F5) were added.
//
// Pattern: @Observable @MainActor final class (CLAUDE.md convention for iOS managers).

import Foundation

/// One undoable user action. `undo`/`redo` are async throwing closures that perform the ACTUAL
/// network mutation (PATCH the before-state / PATCH the after-state, soft-delete / restore,
/// delete / re-create) — this struct carries no project data itself, only the two closures that
/// know how to move between the two states. Every call site captures whatever before/after field
/// values it needs into these closures at record time.
struct UndoableAction {
    let label: String
    let undo: () async throws -> Void
    let redo: () async throws -> Void
}

/// Thrown by an `undo` closure when restoring a soft-deleted clip/audio clip 404s because it was
/// already purged (past the backend's 24h undo window, B1.5) — EditorHistory drops the action
/// entirely instead of re-queuing it (there's nothing left to redo either), and the caller
/// (EditorView) surfaces "Can't undo — file was removed" instead of a generic error toast.
struct PurgedRestoreError: Error {}

@Observable
@MainActor
final class EditorHistory {
    private(set) var undoStack: [UndoableAction] = []
    private(set) var redoStack: [UndoableAction] = []
    private(set) var isProcessing = false

    /// Drives the undo/redo buttons' visibility (F8 exact spec): undo HIDDEN until non-empty,
    /// redo HIDDEN until non-empty (redo only ever appears after at least one undo).
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records a new user action. A new action always invalidates any pending redo path (standard
    /// undo/redo convention — you can't redo into a future that a new edit just overwrote).
    func record(_ action: UndoableAction) {
        undoStack.append(action)
        redoStack.removeAll()
    }

    @discardableResult
    func undo() async -> String? {
        guard !isProcessing, let action = undoStack.popLast() else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await action.undo()
            redoStack.append(action)
            return nil
        } catch is PurgedRestoreError {
            return "Can't undo — file was removed"
        } catch {
            print("[EditorHistory] undo '\(action.label)' error: \(error)")
            return "Couldn't undo"
        }
    }

    @discardableResult
    func redo() async -> String? {
        guard !isProcessing, let action = redoStack.popLast() else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await action.redo()
            undoStack.append(action)
            return nil
        } catch {
            print("[EditorHistory] redo '\(action.label)' error: \(error)")
            return "Couldn't redo"
        }
    }
}
