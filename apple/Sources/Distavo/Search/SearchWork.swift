import Foundation

/// Runs index work on one dedicated background queue so `SearchIndex`'s
/// synchronous (queue-serialised) calls never block Swift-concurrency
/// cooperative-pool threads or the main thread.
enum SearchWork {
    private static let queue = DispatchQueue(label: "es.joanmarcriera.distavo.search-work", qos: .utility)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work()) }
        }
    }

    static func fire(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}
