import CodexCastCore
import CodexCastPersistence
import Foundation
import Testing

@testable import CodexCastPipeline

@Suite("Pipeline settings resolution")
struct PipelineResolutionTests {
    @Test("A fresh show inherits the global defaults, with provenance")
    func freshShowInherits() {
        let resolved = PipelineResolver.resolve(show: PipelineSettings())

        let download = resolved.first { $0.stage == .download }!
        #expect(download.enabled.value)
        #expect(download.enabled.origin == .global)
        #expect(download.trigger.value == .wifiOnly)

        // Chapters are off by default — useful, least essential, not free.
        let chapters = resolved.first { $0.stage == .chapters }!
        #expect(!chapters.enabled.value)
    }

    /// §9.4: disabling an upstream stage must make downstream stages visibly
    /// blocked — "scan with nothing to scan" is a bug, not a user choice.
    @Test("Disabling transcription blocks ad scan with a visible reason")
    func disabledPrerequisiteBlocks() {
        var settings = PipelineSettings()
        settings.transcribe.enabled = .override(false)

        let resolved = PipelineResolver.resolve(show: settings)
        let adScan = resolved.first { $0.stage == .adScan }!

        #expect(adScan.enabled.value)          // still configured on…
        #expect(adScan.blockedBy == .transcribe) // …but visibly blocked
        #expect(!adScan.isActive)
    }

    @Test("Blocking is transitive: no download means no scan either")
    func transitiveBlocking() {
        var settings = PipelineSettings()
        settings.download.enabled = .override(false)

        let resolved = PipelineResolver.resolve(show: settings)

        #expect(resolved.first { $0.stage == .transcribe }?.blockedBy == .download)
        #expect(resolved.first { $0.stage == .adScan }?.blockedBy != nil)
    }

    @Test("Enabling a downstream stage reports which prerequisites need enabling")
    func prerequisitesToEnable() {
        var settings = PipelineSettings()
        settings.download.enabled = .override(false)
        settings.transcribe.enabled = .override(false)

        let needed = PipelineResolver.prerequisitesToEnable(.adScan, show: settings)

        #expect(Set(needed) == [.download, .transcribe])
    }

    @Test("A per-show trigger override wins over the global trigger")
    func triggerOverride() {
        var settings = PipelineSettings()
        settings.adScan.trigger = .override(.onPublish)

        let resolved = PipelineResolver.resolve(show: settings)
        let adScan = resolved.first { $0.stage == .adScan }!

        #expect(adScan.trigger.value == .onPublish)
        #expect(adScan.trigger.origin == .show)
    }

    @Test("Settings round-trip through JSON for podcast-row storage")
    func settingsRoundTrip() throws {
        var settings = PipelineSettings()
        settings.chapters.enabled = .override(true)
        settings.adScan.trigger = .override(.manual)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: data)

        #expect(decoded == settings)
    }
}

@Suite("Job queue")
struct JobQueueTests {
    private func makeQueue() throws -> (JobQueue, AppDatabase) {
        let database = try AppDatabase.inMemory()
        return (try JobQueue(database: database), database)
    }

    @Test("Jobs run in priority order, oldest first within a priority")
    func priorityOrder() async throws {
        let (queue, _) = try makeQueue()

        try await queue.enqueue(kind: .download, episodeId: "old", priority: 0)
        try await queue.enqueue(kind: .download, episodeId: "urgent", priority: 10)
        try await queue.enqueue(kind: .download, episodeId: "newer", priority: 0)

        #expect(try await queue.claimNext()?.episodeId == "urgent")
        #expect(try await queue.claimNext()?.episodeId == "old")
        #expect(try await queue.claimNext()?.episodeId == "newer")
    }

    /// §9.7: one transcription at a time — a second one must wait, but
    /// non-exclusive work may proceed alongside.
    @Test("A second transcription waits while one runs; downloads do not")
    func exclusiveKinds() async throws {
        let (queue, _) = try makeQueue()

        try await queue.enqueue(kind: .transcribe, episodeId: "a")
        try await queue.enqueue(kind: .transcribe, episodeId: "b")
        try await queue.enqueue(kind: .download, episodeId: "c")

        let first = try await queue.claimNext()
        #expect(first?.kind == .transcribe)

        // Next claim skips the second transcription but yields the download.
        let second = try await queue.claimNext()
        #expect(second?.kind == .download)
        #expect(try await queue.claimNext() == nil)

        // Completing the first frees the lane.
        try await queue.complete(first!)
        #expect(try await queue.claimNext()?.episodeId == "b")
    }

    @Test("Enqueueing the same work twice is a no-op")
    func deduplication() async throws {
        let (queue, _) = try makeQueue()

        let first = try await queue.enqueue(kind: .download, episodeId: "ep")
        let duplicate = try await queue.enqueue(kind: .download, episodeId: "ep")

        #expect(first != nil)
        #expect(duplicate == nil)
    }

    /// §9.7: jobs stuck `running` at launch mean the app died mid-job.
    @Test("Orphaned running jobs reset to pending at launch")
    func orphanRecovery() async throws {
        let (queue, database) = try makeQueue()

        try await queue.enqueue(kind: .transcribe, episodeId: "ep")
        _ = try await queue.claimNext()

        // Simulate a relaunch.
        let recovered = try await JobQueue(database: database).recoverOrphans()

        #expect(recovered == 1)
        #expect(try await queue.claimNext()?.episodeId == "ep")
    }

    @Test("Failures retry until the attempt limit, then fail permanently")
    func retryLimit() async throws {
        let (queue, _) = try makeQueue()
        try await queue.enqueue(kind: .download, episodeId: "flaky")

        for attempt in 1...JobQueue.maxAttempts {
            let job = try #require(try await queue.claimNext())
            #expect(job.attemptCount == attempt)
            try await queue.fail(job, error: "network down")
        }

        #expect(try await queue.claimNext() == nil)
        let failed = try await queue.jobs(inState: .failed)
        #expect(failed.count == 1)
        #expect(failed.first?.lastError == "network down")
    }

    /// Thermal and Low Power pauses are not failures (§5.3.7).
    @Test("A thermal requeue does not consume an attempt")
    func requeuePreservesAttempts() async throws {
        let (queue, _) = try makeQueue()
        try await queue.enqueue(kind: .scan, episodeId: "ep")

        let job = try #require(try await queue.claimNext())
        #expect(job.attemptCount == 1)
        try await queue.requeue(job)

        let again = try #require(try await queue.claimNext())
        #expect(again.attemptCount == 1)
    }
}
