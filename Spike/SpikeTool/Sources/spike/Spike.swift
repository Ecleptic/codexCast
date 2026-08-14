// Phase 0 comparison — arms that need no language model.
//
// Usage:
//   spike arm4      classical audio features, no LLM
//
// (Arm 1 lives in the separate `spikelm` binary because it links
// FoundationModels, which this Mac's OS only partially supports.)

import CodexCastDetection
import Foundation
import SpikeShared

@main
struct Spike {
    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "arm4":
                try await Arm4.run()
            default:
                print("usage: spike arm4")
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
