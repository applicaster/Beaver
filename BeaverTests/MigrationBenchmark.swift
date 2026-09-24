//
//  MigrationBenchmark.swift
//  BeaverTests
//
//  Times opening a real store — every pending migration included — on a
//  copy, so the original is never touched. Opt-in, and release only:
//  DEBUG builds set `eraseDatabaseOnSchemaChange`.
//
//      BEAVER_MIGRATION_DB=/path/to/store.sqlite \
//        swift test -c release -Xswiftc -enable-testing --filter MigrationBenchmark
//

import Testing
import Foundation
import GRDB
@testable import BeaverCore

@Suite("MigrationBenchmark", .enabled(if: ProcessInfo.processInfo.environment["BEAVER_MIGRATION_DB"] != nil))
struct MigrationBenchmark {

    @Test("Open and migrate a copy of a real store")
    func migrateCopy() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEAVER_MIGRATION_DB"]!)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("beaver-migrate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: source, to: copy)
        // Bring the copy to where installs are today, so only this
        // release's migrations are timed.
        do {
            let queue = try DatabaseQueue(path: copy.path)
            try Schema.migrator().migrate(queue, upTo: "v6_network_bookmark")
            try queue.close()
        }

        let elapsed = try ContinuousClock().measure {
            _ = try LogStore(source: .onDisk(copy))
        }
        let size = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int ?? 0
        print("MigrationBenchmark: v6 -> latest on a \(size / 1_000_000) MB store in \(elapsed)")
    }
}
