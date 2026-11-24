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
    private var converterInputFormat: AVAudioFormat?
    private var pcmOutBuffer: AVAudioPCMBuffer?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRunning = false

    /// Called from the audio thread with a 0…1 loudness value for each buffer.
    var onLevel: ((CGFloat) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        samples.reserveCapacity(16_000 * 60)  // pre-allocate 60 s so real-time tap avoids reallocs
        // If the input device changes mid-recording (AirPods connect, USB mic unplugged), carry on
        // with the new device instead of silently recording nothing.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning else { return }
                debugLog("audio device changed, restarting input")
                self.converter = nil
                self.converterInputFormat = nil
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
        if !isRunning {
            try startEngine()
            isRunning = true
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        if converter == nil || converterInputFormat != format {
            converter = AVAudioConverter(from: format, to: target)
            converterInputFormat = format
        } else {
            converter?.reset()
        }
        input.removeTap(onBus: 0)
        // 1024 frames (~21 ms at 48 kHz) gives responsive ~47 Hz level metering and low stop latency.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let neededCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        let out: AVAudioPCMBuffer
        if let existing = pcmOutBuffer, existing.frameCapacity >= neededCapacity {
            existing.frameLength = 0
            out = existing
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(neededCapacity, 1024)) else {
                return
            }
            pcmOutBuffer = created
            out = created
        }

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
        let count = Int(out.frameLength)
        guard error == nil, count > 0, let channel = out.floatChannelData else { return }
        let ptr = UnsafeBufferPointer(start: channel[0], count: count)

        lock.lock()
        samples.append(contentsOf: ptr)
        lock.unlock()

        if let onLevel {
            var sumSquares: Float = 0
            for i in 0..<count {
                let s = ptr[i]
                sumSquares += s * s
            }
            let rms = sqrt(sumSquares / Float(count))
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
