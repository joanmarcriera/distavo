import Foundation
import XCTest

/// Per-test temporary directory (#6647; a copy of DistavoCoreTests/TestTemp.swift, test targets share no file). Tests used `FileManager.default.temporaryDirectory`
/// and many never removed what they made: thousands of `distavo-*` directories piled up.
///
/// `TestTemp.root` is a directory private to the RUNNING test. An XCTest observer removes it
/// when the test finishes, so every test cleans up even if it forgot to (and even when it failed).
/// The base is `$TMPDIR` when set (`FileManager.temporaryDirectory` ignores it on macOS, so a
/// private TMPDIR was never honoured), else the system temp directory.
///
/// Usage: `TestTemp.root.appendingPathComponent("distavo-x-\(UUID().uuidString)")`.
enum TestTemp {
    private static let lock = NSLock()
    private static var current: URL?
    private static var observing = false

    private final class Observer: NSObject, XCTestObservation {
        func testCaseDidFinish(_ testCase: XCTestCase) { TestTemp.cleanup() }
    }
    private static let observer = Observer()

    static var base: URL {
        if let t = ProcessInfo.processInfo.environment["TMPDIR"], !t.isEmpty {
            return URL(fileURLWithPath: t, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    /// The running test's private directory, created on first use.
    static var root: URL {
        lock.lock(); defer { lock.unlock() }
        if !observing {
            observing = true
            // XCTest allows observer registration on the main thread only, and an `async` test body runs
            // off it. Off main, register asynchronously: if the observer misses this test's end, the next
            // test's end removes `current` all the same (cleanup removes whatever dir is current).
            if Thread.isMainThread {
                register()
            } else {
                DispatchQueue.main.async { TestTemp.register() }
            }
        }
        if let current { return current }
        let dir = base.appendingPathComponent("distavo-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Fail here, with the path, rather than later with a confusing "no such file" (review of o).
            preconditionFailure("TestTemp: cannot create \(dir.path): \(error)")
        }
        current = dir
        return dir
    }

    private static func register() { XCTestObservationCenter.shared.addTestObserver(observer) }

    /// Removes the current test's directory (called by the observer after each test).
    static func cleanup() {
        lock.lock(); defer { lock.unlock() }
        if let dir = current { try? FileManager.default.removeItem(at: dir) }
        current = nil
    }
}
