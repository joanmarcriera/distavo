import SwiftUI
import DistavoCore
import DistavoEmbedded

/// "Benchmark this Mac" (Vikunja #2160): runs every downloaded engine on a
/// 30 s fixture and shows seconds per minute of audio and peak memory, so
/// the model suggestion is measured rather than assumed. Progress comes
/// through `controller.modelProgress` (the coordinator's one handler).
struct BenchmarkButton: View {
    @ObservedObject var controller: WatcherController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(controller.benchmarkRunning ? "Benchmarking…" : "Benchmark this Mac") {
                    controller.runBenchmark()
                }
                .disabled(controller.benchmarkRunning || !EmbeddedModelStore.hasDownloadedModels())
                HelpButton(text: "Times each downloaded model on 30 seconds of a recent recording (or a spoken sample made on this Mac) and records the peak memory. Nothing is downloaded or sent anywhere. The result drives the model suggestion and unlocks models this Mac has proven it can run.")
            }
            if controller.benchmarkRunning, let progress = controller.modelProgress {
                Text(progress).font(.caption).foregroundStyle(.secondary)
            } else if let caption = Benchmark.caption(controller.config.benchmark) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Text("Recommended for this Mac: \(Benchmark.recommended(results: controller.config.benchmark, memoryBytes: HardwareProbe.physicalMemoryBytes).displayName).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
