// Microphone capture, converted to 16 kHz mono for the speech model.
// All public methods must be called on `queue`.

import AVFoundation

enum RecorderError: LocalizedError {
    case noMicrophone
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone found"
        case .permissionDenied: return "Microphone access is off"
        }
    }
}

final class Recorder {
    let queue: DispatchQueue
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRunning = false

    /// Called from the audio thread with a 0…1 loudness value for each buffer.
    var onLevel: ((CGFloat) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        // If the input device changes mid-recording (AirPods connect, USB mic unplugged), carry on
        // with the new device instead of silently recording nothing.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning else { return }
                debugLog("audio device changed, restarting input")
                try? self.startEngine()
            }
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.permissionDenied
        }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        try startEngine()
        isRunning = true
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
        if !chunk.isEmpty, let onLevel {
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            let db = 20 * log10(max(rms, 1e-6))
            onLevel(CGFloat(min(1, max(0, (db + 55) / 40))))  // ~-55 dB silence → 0, ~-15 dB loud → 1
        }
    }

    /// Stops the mic and returns everything recorded since `start()`.
    @discardableResult
    func stop() -> [Float] {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
