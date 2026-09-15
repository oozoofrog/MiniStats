#if DEBUG
import SwiftUI

// MARK: - Sample data

private let sampleEntries: [CacheEntry] = [
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/MyApp-gjklmneeqwertyuiopasdfgh/Build", size: 1_820_000_000, workspace: "MyApp", candidate: true),
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/RetroStats-abcdefghijklmnopqrstuvwxyz12/Build", size: 1_240_000_000, workspace: "RetroStats", candidate: true),
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/KernelDriver-qwertyuiopasdfghjkl/Build", size: 980_000_000, workspace: "KernelDriver", candidate: true),
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/LegacyFramework-mnbvcxzlkjhgfdsapoi/Build", size: 760_000_000, workspace: "LegacyFramework", candidate: true),
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/CLIUtils-1234567890qwertyuiopasdf/Build", size: 520_000_000, workspace: "CLIUtils", candidate: true),
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/Recent-zyxwvutsrqponmlkjihgfedcba/Build", size: 1_100_000_000, workspace: "Recent", candidate: false)
]

private let staleEntries: [CacheEntry] = [
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/Recent-zyxwvutsrqponmlkjihgfedcba/Build", size: 1_100_000_000, workspace: "Recent", candidate: false),
    .init(path: "/Users/dev/Library/Developer/Xcode/DerivedData/AnotherApp-1234567890qwertyuiop/Build", size: 820_000_000, workspace: "AnotherApp", candidate: false)
]

private func makeReport(entries: [CacheEntry] = sampleEntries) -> CacheReport {
    CacheReport(
        generatedAt: Date().timeIntervalSince1970,
        hours: 8,
        totalBytes: entries.reduce(Int64(0)) { $0 + $1.size },
        candidateBytes: entries.filter(\.candidate).reduce(Int64(0)) { $0 + $1.size },
        items: entries
    )
}

private func makeConfirmProgress() -> CleanProgress {
    let candidates = Array(sampleEntries.filter(\.candidate).prefix(3))
    return CleanProgress(
        phase: .confirming,
        items: candidates.map { CleanProgress.Item(path: $0.path, size: $0.size) },
        freedBytes: 0, cancelled: false, currentPath: nil, summary: nil, error: nil
    )
}

private func makeRunningProgress() -> CleanProgress {
    let candidates = Array(sampleEntries.filter(\.candidate).prefix(4))
    return CleanProgress(
        phase: .running,
        items: [
            .init(path: candidates[0].path, size: candidates[0].size, state: .deleted),
            .init(path: candidates[1].path, size: candidates[1].size, state: .deleting),
            .init(path: candidates[2].path, size: candidates[2].size, state: .pending),
            .init(path: candidates[3].path, size: candidates[3].size, state: .kept),
        ],
        freedBytes: candidates[0].size, cancelled: false,
        currentPath: candidates[1].path, summary: nil, error: nil
    )
}

private func makeDoneProgress() -> CleanProgress {
    let candidates = sampleEntries.filter(\.candidate)
    return CleanProgress(
        phase: .done,
        items: candidates.map { .init(path: $0.path, size: $0.size, state: $0.size > 900_000_000 ? .deleted : .kept) },
        freedBytes: candidates.filter { $0.size > 900_000_000 }.reduce(Int64(0)) { $0 + $1.size },
        cancelled: false, currentPath: nil, summary: nil, error: nil
    )
}

private func makeCancelledProgress() -> CleanProgress {
    let candidates = sampleEntries.filter(\.candidate)
    return CleanProgress(
        phase: .cancelled,
        items: [
            .init(path: candidates[0].path, size: candidates[0].size, state: .deleted),
            .init(path: candidates[1].path, size: candidates[1].size, state: .deleting),
            .init(path: candidates[2].path, size: candidates[2].size, state: .pending),
            .init(path: candidates[3].path, size: candidates[3].size, state: .pending),
        ],
        freedBytes: candidates[0].size, cancelled: true, currentPath: nil, summary: nil, error: nil
    )
}

private func makeFailedProgress() -> CleanProgress {
    let candidates = Array(sampleEntries.filter(\.candidate).prefix(3))
    return CleanProgress(
        phase: .failed,
        items: [
            .init(path: candidates[0].path, size: candidates[0].size, state: .deleted),
            .init(path: candidates[1].path, size: candidates[1].size, state: .failed),
            .init(path: candidates[2].path, size: candidates[2].size, state: .pending),
        ],
        freedBytes: candidates[0].size, cancelled: false, currentPath: nil,
        summary: nil, error: "일부 항목을 삭제할 수 없습니다: 작업이 허용되지 않습니다 (운영 체제 오류 -1)"
    )
}

private func storageModel(_ storage: StorageController) -> DashboardModel {
    let model = DashboardModel()
    model.page = .storage
    model.storage = storage
    return model
}

// MARK: - DerivedData cleanup screen

#Preview("스토리지 정리 — 후보 목록") {
    DashboardView(model: storageModel(.preview(report: makeReport())))
}

#Preview("스토리지 정리 — 후보 없음") {
    DashboardView(model: storageModel(.preview(report: makeReport(entries: staleEntries))))
}

#Preview("스토리지 정리 — 용량 조회 중") {
    DashboardView(model: storageModel(.preview(busy: true)))
}

#Preview("스토리지 정리 — 조회 오류") {
    DashboardView(model: storageModel(.preview(report: makeReport(), lastError: "DerivedData 경로를 읽을 수 없습니다: 권한 거부됨")))
}

#Preview("스토리지 정리 — 삭제 확인") {
    DashboardView(model: storageModel(.preview(cleanProgress: makeConfirmProgress())))
}

#Preview("스토리지 정리 — 정리 진행 중") {
    DashboardView(model: storageModel(.preview(cleanProgress: makeRunningProgress())))
}

#Preview("스토리지 정리 — 정리 완료") {
    DashboardView(model: storageModel(.preview(cleanProgress: makeDoneProgress())))
}

#Preview("스토리지 정리 — 정리 취소") {
    DashboardView(model: storageModel(.preview(cleanProgress: makeCancelledProgress())))
}

#Preview("스토리지 정리 — 정리 실패") {
    DashboardView(model: storageModel(.preview(cleanProgress: makeFailedProgress())))
}
#endif
