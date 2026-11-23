// Speech-to-text: NVIDIA Parakeet TDT 0.6B v3 running on the Neural Engine via FluidAudio.

import FluidAudio
import Foundation

actor Transcriber {
    private var manager: AsrManager?
    private var decoderLayers = 2

    /// True when the model files are on disk.
    nonisolated static var modelInstalled: Bool {
        let fm = FileManager.default
        return ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc"]
            .allSatisfy { fm.fileExists(atPath: modelDir.appendingPathComponent($0).path) }
    }

    var isLoaded: Bool { manager != nil }

    /// Loads the model from disk. Never touches the network.
    func load() throws {
        if manager != nil { return }
        let models = try AsrModels.loadLocal(from: modelDir, version: .v3)
        decoderLayers = models.version.decoderLayers
        manager = AsrManager(config: .default, models: models)
    }

    /// One-time model download (only when the user asks for it in Settings).
    func download() async throws {
        _ = try await AsrModels.download(version: .v3)
        manager = nil
        try load()
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try load()
        guard let manager else { return "" }
        var padded = samples
        if padded.count < 16_000 {  // the model needs at least ~1 s of audio
            padded += [Float](repeating: 0, count: 16_000 - padded.count)
        }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(padded, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(file url: URL) async throws -> String {
        try load()
        guard let manager else { return "" }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(url, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
