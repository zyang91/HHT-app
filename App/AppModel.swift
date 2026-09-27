import Foundation
import SwiftUI
import HHTCore

/// Owns the database and services; views observe `revision` to reload after any change.
@MainActor
final class AppModel: ObservableObject {
    /// One instance per process: shared by the SwiftUI scene and the app delegate (background relaunches).
    static let shared = AppModel()

    let store: TravelStore
    let engine: InferenceEngine
    let edit: EditService
    let collector: LocationCollector
    let motion: MotionSync
    let geocoder: PlaceGeocoder

    @Published private(set) var revision = 0
    @Published var errorMessage: String?
    @Published private(set) var isProcessing = false

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HHT", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Visible in the Files app (On My iPhone › HHT) because UIFileSharingEnabled is set.
    static var documentsDirectory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var exportsDirectory: URL { documentsDirectory.appendingPathComponent("Exports", isDirectory: true) }
    static var backupsDirectory: URL { documentsDirectory.appendingPathComponent("Backups", isDirectory: true) }

    init() {
        let path = Self.supportDirectory.appendingPathComponent("travel.sqlite")
        do {
            store = try TravelStore(path: path.path)
        } catch {
            fatalError("Cannot open database at \(path.path): \(error)")
        }
        engine = InferenceEngine(store: store)
        edit = EditService(store: store)
        collector = LocationCollector(store: store)
        motion = MotionSync(store: store)
        geocoder = PlaceGeocoder(store: store)
        engine.onPlaceCreated = { [weak self] p in
            Task { @MainActor in self?.geocoder.enqueue(p.id) }
        }
        collector.profile = LocationCollector.Profile(rawValue: UserDefaults.standard.string(forKey: "collectorProfile") ?? "") ?? .balanced
        collector.onStationary = { [weak self] in
            Task { @MainActor in await self?.runInference() }
        }
    }

    private var launched = false

    /// Safe to call repeatedly (delegate launch, scene appear).
    func launch() {
        guard !launched else { return }
        launched = true
        collector.resumeIfEnabled()
        #if targetEnvironment(simulator)
        // launch argument `-hhtDemo YES` seeds demo data (simulator builds only)
        if UserDefaults.standard.bool(forKey: "hhtDemo") && store.pointCount() == 0 {
            UserDefaults.standard.set(true, forKey: "onboarded")
            try? DemoData.generate(into: store)
        }
        #endif
        Task { await runInference() }
        autoBackupIfDue()
    }

    /// Sync motion history, then reconstruct visits/trips from new observations.
    func runInference() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        await motion.sync()
        do {
            try engine.processNew()
        } catch {
            errorMessage = "Inference failed: \(error)"
        }
        revision += 1
    }

    /// Reprocess a range from raw data (user edits are kept).
    func reprocess(from: Date, to: Date) async {
        isProcessing = true
        defer { isProcessing = false }
        await motion.sync()
        do { try engine.process(from: from, to: to) } catch { errorMessage = "Reprocessing failed: \(error)" }
        revision += 1
    }

    /// Run an edit; report errors; refresh views.
    func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        revision += 1
    }

    func touch() { revision += 1 }

    // MARK: - Backups

    /// Daily SQLite snapshot into Documents/Backups (keeps the last 7). Never deletes anything else.
    func autoBackupIfDue() {
        let key = "lastAutoBackup"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400, store.pointCount() > 0 else { return }
        do {
            try backupNow()
            UserDefaults.standard.set(Date(), forKey: key)
        } catch {
            NSLog("HHT: backup failed \(error)")
        }
    }

    @discardableResult
    func backupNow() throws -> URL {
        let dir = Self.backupsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("travel-\(f.string(from: Date())).sqlite")
        try store.backup(to: url)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let snapshots = files.filter { $0.lastPathComponent.hasPrefix("travel-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in snapshots.dropFirst(7) { try? FileManager.default.removeItem(at: old) }
        return url
    }
}
