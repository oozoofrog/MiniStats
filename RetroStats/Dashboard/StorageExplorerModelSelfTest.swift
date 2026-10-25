import AppKit

@MainActor func storageExplorerModelSelfTest() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "StorageExplorerModelSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let queue = DispatchQueue(label: "RetroStats.explorer-cancellation-test")
    queue.suspend()
    let model = StorageExplorerModel(queue: queue)
    let volume = StorageVolume(id: "fixture-volume", name: "Before", path: "/Volumes/Before", location: .external,
                               isMain: false, capacity: .init(total: 100, free: 20), sharedContainerID: nil, measuredAt: Date())
    model.open(volume)
    model.cancel()
    queue.resume()
    let deadline = Date().addingTimeInterval(2)
    while model.running && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try require(!model.running, "Pre-start cancellation must release Explorer's running state")
    let renamed = StorageVolume(id: volume.id, name: "After", path: "/Volumes/After", location: .external,
                                isMain: false, capacity: volume.capacity, sharedContainerID: nil, measuredAt: Date())
    queue.suspend()
    model.open(volume)
    model.reconcile(renamed)
    let reset = model.path == nil && model.result == nil && !model.running
    queue.resume()
    try require(reset, "Rename with the same volume UUID must discard the old path and result")
    model.open(renamed)
    try require(model.path == renamed.path, "New scan must target the renamed mount")
    model.reset()
    print("PASS: queued cancellation releases Explorer; mount rename invalidates old paths without changing volume selection")
}
