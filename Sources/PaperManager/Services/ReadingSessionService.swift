import AppKit
import Combine

/// Explicit sessions work with any external reader. No page/window surveillance.
/// One session per library, shared by all inspectors, with incremental durable writes.
@MainActor
final class ReadingSessionService: ObservableObject {
    @Published private(set) var activePaperID: UUID?
    @Published private(set) var errorMessage: String?
    private weak var store: LibraryStore?
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var pendingSeconds: TimeInterval = 0
    private var pendingPaperID: UUID?
    private var sleepObserver: NSObjectProtocol?
    private static let sessions = NSHashTable<ReadingSessionService>.weakObjects()

    init(store: LibraryStore) {
        self.store = store
        Self.sessions.add(self)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in _ = self?.pause() } }
    }

    deinit {
        timer?.invalidate()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    @discardableResult
    func start(_ id: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard pause(now: now), store?.paper(with: id) != nil else { return false }
        activePaperID = id
        pendingPaperID = id
        lastTick = now
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard activePaperID != nil else { return }
        let elapsed = now - lastTick
        lastTick = now
        // Ignore sleep, debugger stalls and clock anomalies instead of inventing time.
        if elapsed >= 0 && elapsed <= 15 { pendingSeconds += elapsed }
        if !flush() || elapsed > 15 {
            timer?.invalidate(); timer = nil
            activePaperID = nil
        }
    }

    @discardableResult
    func pause(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        tick(now: now)
        timer?.invalidate(); timer = nil
        activePaperID = nil
        return flush()
    }

    @discardableResult
    private func flush() -> Bool {
        guard pendingSeconds > 0, let id = pendingPaperID, let store else { return true }
        // A deleted record must never be recreated by a running timer.
        guard store.paper(with: id) != nil else {
            pendingSeconds = 0; activePaperID = nil; timer?.invalidate(); timer = nil
            return true
        }
        do {
            try store.updateReading(id) { $0.add(seconds: pendingSeconds) }
            pendingSeconds = 0
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    static func pauseAll() -> Bool {
        sessions.allObjects.map { $0.pause() }.allSatisfy { $0 }
    }
}

extension LibraryStore {
    /// Merge into the latest record so timer ticks cannot overwrite metadata drafts.
    func updateReading(_ id: UUID, change: (inout ReadingRecord) -> Void) throws {
        guard var paper = paper(with: id) else { throw PaperManagerError.message("文献已被其他窗口移除。") }
        var record = paper.reading ?? ReadingRecord()
        change(&record)
        paper.reading = record
        try updatePaperDurably(paper)
    }
}
