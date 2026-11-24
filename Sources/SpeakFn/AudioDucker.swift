// Smoothly lowers ("ducks") background system audio while recording so music and speech don't compete,
// then restores the exact previous volume when recording ends.

import AudioToolbox
import CoreAudio
import Foundation

final class AudioDucker: @unchecked Sendable {
    static let shared = AudioDucker()

    private let queue = DispatchQueue(label: "speakfn.ducker", qos: .userInteractive)
    private var generation: UInt64 = 0
    private var savedDevice: AudioDeviceID?
    private var savedVolume: Float32?
    private var appliedVolume: Float32?
    private var usedHardwareMute = false
    private var termSources: [DispatchSourceSignal] = []

    private init() {
        // Ensure volume is restored even if the process is terminated mid-recording.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInteractive))
            src.setEventHandler { [weak self] in
                self?.restoreImmediately()
                exit(0)
            }
            src.resume()
            termSources.append(src)
        }
    }

    /// True while system output volume is currently lowered by SpeakFn.
    private(set) var isDucked = false

    /// Smoothly lowers background audio to `ratio` (0 = mute, 0.15 = 15% of current volume).
    func duck(ratio: Double) {
        let clampedRatio = Float32(max(0, min(0.8, ratio)))
        queue.async { [weak self] in
            self?.performDuck(ratio: clampedRatio)
        }
    }

    /// Smoothly restores the user's previous volume.
    func unduck() {
        queue.async { [weak self] in
            self?.performUnduck(smooth: true)
        }
    }

    /// Synchronous immediate restore for app quit / signal termination.
    func restoreImmediately() {
        queue.sync {
            performUnduck(smooth: false)
        }
    }

    // MARK: - Internal (runs on `queue`)

    private func performDuck(ratio: Float32) {
        generation &+= 1
        let gen = generation

        guard let device = defaultOutputDevice(), device != kAudioObjectUnknown else { return }
        // Never touch an output that the user already muted.
        if isDeviceMuted(device) { return }

        // If already ducked on the same device, just adjust from the saved baseline.
        let baseline: Float32
        if isDucked, savedDevice == device, let existing = savedVolume {
            baseline = existing
        } else {
            if isDucked { performUnduck(smooth: false) }
            guard let current = readVolume(device) else {
                // Fixed-volume output (e.g. some HDMI monitors): fall back to temporary mute.
                if setDeviceMuted(device, muted: true) {
                    savedDevice = device
                    savedVolume = nil
                    appliedVolume = nil
                    usedHardwareMute = true
                    isDucked = true
                }
                return
            }
            guard current > 0.01 else { return }
            baseline = current
            savedDevice = device
            savedVolume = baseline
            usedHardwareMute = false
        }

        let target = ratio <= 0.02 ? Float32(0.0) : min(baseline, max(0.02, baseline * ratio))
        guard target < baseline - 0.005 else { return }

        isDucked = true
        let startVol = readVolume(device) ?? baseline
        let steps = 4
        for step in 1...steps {
            guard generation == gen else { return }
            let t = Float32(step) / Float32(steps)
            let v = startVol + (target - startVol) * t
            _ = writeVolume(device, volume: v)
            appliedVolume = v
            if step < steps { usleep(18_000) }  // ~72 ms smooth dip
        }
        if ratio <= 0.02 {
            _ = setDeviceMuted(device, muted: true)
            usedHardwareMute = true
        }
        debugLog("ducked audio \(String(format: "%.2f -> %.2f", baseline, target))")
    }

    private func performUnduck(smooth: Bool) {
        generation &+= 1
        let gen = generation
        guard isDucked, let device = savedDevice else {
            clearState()
            return
        }

        if usedHardwareMute {
            _ = setDeviceMuted(device, muted: false)
        }

        if let target = savedVolume {
            let current = readVolume(device)
            // Respect manual volume changes if the user pressed volume keys mid-recording.
            let userChangedVolume: Bool = {
                guard let current, let applied = appliedVolume else { return false }
                return abs(current - applied) > 0.07
            }()

            if !userChangedVolume {
                if smooth, let startVol = current, abs(target - startVol) > 0.02 {
                    let steps = 5
                    for step in 1...steps {
                        guard generation == gen else { return }
                        let t = Float32(step) / Float32(steps)
                        // Ease-out curve so volume swells gently back up.
                        let eased = 1 - (1 - t) * (1 - t)
                        let v = startVol + (target - startVol) * eased
                        _ = writeVolume(device, volume: v)
                        if step < steps { usleep(32_000) }  // ~160 ms smooth restore
                    }
                } else {
                    _ = writeVolume(device, volume: target)
                }
                debugLog("restored audio to \(String(format: "%.2f", target))")
            } else {
                debugLog("kept manual volume change during dictation")
            }
        }
        clearState()
    }

    private func clearState() {
        isDucked = false
        savedDevice = nil
        savedVolume = nil
        appliedVolume = nil
        usedHardwareMute = false
    }

    // MARK: - CoreAudio HAL helpers

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func readVolume(_ device: AudioDeviceID) -> Float32? {
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &virtualAddr) {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &virtualAddr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        // Fallback: master scalar (element 0) or left channel (element 1).
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(device, &addr) {
                var vol: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
                    return vol
                }
            }
        }
        return nil
    }

    private func writeVolume(_ device: AudioDeviceID, volume: Float32) -> Bool {
        var clamped = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float32>.size)

        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &virtualAddr),
            AudioObjectIsPropertySettable(device, &virtualAddr, &settable) == noErr,
            settable.boolValue
        {
            return AudioObjectSetPropertyData(device, &virtualAddr, 0, nil, size, &clamped) == noErr
        }

        // Fallback: write master or stereo channels 1 & 2.
        var wrote = false
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var chSettable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &addr),
                AudioObjectIsPropertySettable(device, &addr, &chSettable) == noErr,
                chSettable.boolValue
            {
                if AudioObjectSetPropertyData(device, &addr, 0, nil, size, &clamped) == noErr {
                    wrote = true
                }
            }
        }
        return wrote
    }

    private func isDeviceMuted(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    private func setDeviceMuted(_ device: AudioDeviceID, muted: Bool) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
            AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
            settable.boolValue
        else { return false }
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &val) == noErr
    }
}
