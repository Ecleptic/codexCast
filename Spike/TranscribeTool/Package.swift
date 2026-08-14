// swift-tools-version: 6.4
import PackageDescription

// Mac-side transcription for Phase 0 corpus prep. Throwaway with the rest of
// Spike/ — the app's real transcription lives in CodexCastTranscription and
// runs on the phone.
let package = Package(
    name: "TranscribeTool",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "transcribe")
    ]
)
