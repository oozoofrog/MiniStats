import AppKit

@MainActor final class StorageExplorerModel: ObservableObject {
    @Published private(set) var result: StorageFolderSnapshot?
    @Published private(set) var running = false
    @Published private(set) var error: String?
    @Published private(set) var path: String?
    @Published private(set) var volumeID: String?
    private var rootPath: String?
    private var cancellation: StorageScanCancellation?
    private var generation = 0
    private let queue: DispatchQueue
    init(queue: DispatchQueue = DispatchQueue(label: "RetroStats.folder-explorer", qos: .utility)) { self.queue = queue }
    func reconcile(_ volume: StorageVolume?) {
        guard volumeID != nil else { return }
        let currentRoot = volume.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        if volume?.id != volumeID || currentRoot != rootPath { reset() }
    }

    func open(_ volume: StorageVolume, path requested: String? = nil) {
        let root = URL(fileURLWithPath: volume.path).standardizedFileURL.path
        let target = URL(fileURLWithPath: requested ?? root).standardizedFileURL.path
        guard target == root || target.hasPrefix(root == "/" ? "/" : root + "/") else { return }
        cancellation?.cancel()
        generation += 1
        let current = generation
        let token = StorageScanCancellation()
        cancellation = token
        rootPath = root; path = target; volumeID = volume.id
        result = nil; error = nil; running = true
        queue.async { [weak self] in
            guard !token.isCancelled else {
                DispatchQueue.main.async {
                    guard let self, self.generation == current else { return }
                    self.running = false
                    self.error = "Scan cancelled."
                }
                return
            }
            let outcome = Result {
                guard let identity = StorageVolumeCatalog.identity(at: root), identity.id == volume.id else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
                }
                let snapshot = try StorageFolderScanner.scan(path: target, rootPath: root, expectedDevice: identity.device, cancellation: token)
                guard StorageVolumeCatalog.identity(at: root)?.id == volume.id else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
                }
                return snapshot
            }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.running = false
                switch outcome {
                case .success(let snapshot): self.result = snapshot
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }

    func cancel() { cancellation?.cancel() }
    func reset() {
        cancellation?.cancel(); generation += 1
        running = false; result = nil; error = nil; path = nil; volumeID = nil; rootPath = nil
    }
    var canGoUp: Bool { path != nil && path != rootPath }
    func goUp(_ volume: StorageVolume) {
        guard let path, canGoUp else { return }
        open(volume, path: URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
}
