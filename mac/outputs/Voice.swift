import AppKit
import AVFoundation
import Speech

final class VoiceController: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onInterrupt: (() -> Void)?
    var pauseSeconds = max(2, min(15, UserDefaults.standard.double(forKey: ChefCompatibility.key("ChefPauseSeconds")) == 0 ? 5 : UserDefaults.standard.double(forKey: ChefCompatibility.key("ChefPauseSeconds"))))
    private var spokenText = ""
    private var interruptedTurn = false
    var onTranscript: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onListening: ((Bool) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    var onVoiceNotice: ((String) -> Void)?
    var onCaptureDiagnostic: ((String) -> Void)?
    var onDeactivated: (() -> Void)?
    var onWake: ((String) -> Void)?
    var onActivity: (() -> Void)?
    var preferredVoiceID = UserDefaults.standard.string(forKey: ChefCompatibility.key("ChefVoiceID")) ?? ""
    var acknowledgment = UserDefaults.standard.string(forKey: ChefCompatibility.key("ChefAcknowledgment")) ?? "Yeah, what's up?"
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let speaker = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Timer?
    private var sessionLimit: Timer?
    private var tapInstalled = false
    private var generation = 0
    private var transcript = ""
    private var delivered = false
    private var enabled = false
    private var wakeMode = false
    var fishEnabled = UserDefaults.standard.bool(forKey: ChefCompatibility.key("ChefFishEnabled"))
    var fishConsent = UserDefaults.standard.bool(forKey: ChefCompatibility.key("ChefFishConsent"))
    var fishVoiceID = UserDefaults.standard.string(forKey: ChefCompatibility.key("ChefFishVoiceID")) ?? ""
    private var cloudPlayer: AVAudioPlayer?
    private var cloudTask: Task<Void, Never>?
    private var activeUtterance: AVSpeechUtterance?
    private var speechTurn = SpeechTurn()
    private var speaking = false
    private var authorizationPending = false
    private var recognitionErrors = 0
    private var lastRecognitionDiagnostic = "not started"
    private let captureDiagnosticLock = NSLock()
    private var captureBufferCount: UInt64 = 0
    private var captureAudibleBufferCount: UInt64 = 0
    private var captureRMS: Float = 0
    private var capturePeak: Float = 0
    private var captureSilentBufferCount = 0
    private var captureFallbackQueued = false
    private var lastCaptureDiagnosticPublish: TimeInterval = 0
    private var voiceProcessingFallbackAttempted = false
    private var conversationWindow = ConversationWindow()
    var listening: Bool { engine.isRunning }
    var microphoneEnabled: Bool { enabled }
    var runtimeDiagnostic: String {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechPermission = SFSpeechRecognizer.authorizationStatus()
        captureDiagnosticLock.lock()
        let buffers = captureBufferCount, audible = captureAudibleBufferCount
        let rms = captureRMS, peak = capturePeak
        captureDiagnosticLock.unlock()
        let wakeState = wakeMode && !conversationWindow.active() ? "waiting for wake phrase" : "request active"
        return "Voice diagnostics: mic=\(permission.rawValue), speech=\(speechPermission.rawValue), on-device=\(recognizer?.supportsOnDeviceRecognition == true), available=\(recognizer?.isAvailable == true), engine=\(engine.isRunning ? "running" : "stopped"), enabled=\(enabled), voice-processing=\(engine.inputNode.isVoiceProcessingEnabled), input-muted=\(engine.inputNode.isVoiceProcessingInputMuted), state=\(wakeState), capture=\(buffers) buffers/\(audible) audible, rms=\(String(format: "%.5f", rms)), peak=\(String(format: "%.5f", peak)), retries=\(recognitionErrors), recognition=\(lastRecognitionDiagnostic)"
    }

    override init() { super.init(); speaker.delegate = self }

    func enable(wake: Bool) {
        guard !authorizationPending else { return }
        enabled = true
        wakeMode = wake
        if !wake { conversationWindow.engage() }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && SFSpeechRecognizer.authorizationStatus() == .authorized {
            startSession(); return
        }
        authorizationPending = true
        onStatus?("Allow microphone and speech recognition in the macOS prompts to use voice.")
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            guard allowed else {
                DispatchQueue.main.async { self?.authorizationPending = false; self?.enabled = false; self?.onStatus?("Microphone access is off. Enable Chef in System Settings → Privacy & Security → Microphone.") }
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authorizationPending = false
                    guard status == .authorized else {
                        self.enabled = false
                        self.onStatus?("Speech recognition access is off. Enable Chef in Privacy & Security → Speech Recognition.")
                        return
                    }
                    if self.enabled { self.startSession() }
                }
            }
        }
    }

    func finishNow() { finishTranscript() }
    func setPause(_ seconds: Double) { pauseSeconds = min(15, max(2, seconds)); UserDefaults.standard.set(pauseSeconds, forKey: ChefCompatibility.key("ChefPauseSeconds")) }
    func disable() { enabled = false; conversationWindow.end(); stopSession() }

    private func startSession(preserving carry: String = "") {
        guard enabled else { return }
        stopSession()
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            enabled = false
            onStatus?("On-device English speech recognition is unavailable. Enable English Dictation in macOS Keyboard settings and download its speech assets, then try again.")
            return
        }
        generation += 1
        let current = generation
        captureDiagnosticLock.lock()
        captureBufferCount = 0; captureAudibleBufferCount = 0; captureRMS = 0; capturePeak = 0; captureSilentBufferCount = 0; captureFallbackQueued = false
        captureDiagnosticLock.unlock()
        delivered = false
        transcript = carry
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Hey Chef", "Chef", "Gmail", "YouTube Music", "timer", "Calendar"]
        self.request = request
        let input = engine.inputNode
        // Recognition receives the raw microphone stream. The voice-processing I/O path
        // delivered buffers but produced no transcription on this Mac; explicit
        // interruption/echo checks still guard assistant playback.
        if input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(false) }
        if input.isVoiceProcessingEnabled && input.isVoiceProcessingInputMuted { input.isVoiceProcessingInputMuted = false }
        let voiceProcessingActive = input.isVoiceProcessingEnabled
        // The input node's output bus carries microphone samples; its input bus is not the capture format.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { enabled = false; onStatus?("No working microphone was found."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self else { return }
            let levels = Self.audioLevels(buffer)
            self.captureDiagnosticLock.lock()
            self.captureBufferCount &+= 1
            self.captureRMS = levels.rms; self.capturePeak = levels.peak
            if levels.peak > 0.001 {
                self.captureAudibleBufferCount &+= 1
                self.captureSilentBufferCount = 0
            } else {
                self.captureSilentBufferCount += 1
            }
            let prolongedSilence = !self.captureFallbackQueued && VoiceInteraction.shouldRetryRawCapture(bufferCount: self.captureBufferCount, silentBufferCount: self.captureSilentBufferCount, voiceProcessingActive: voiceProcessingActive, fallbackAttempted: self.voiceProcessingFallbackAttempted)
            if prolongedSilence { self.captureFallbackQueued = true }
            let bufferCount = self.captureBufferCount, audibleCount = self.captureAudibleBufferCount
            let now = Date.timeIntervalSinceReferenceDate
            let shouldPublish = now - self.lastCaptureDiagnosticPublish >= 0.4
            if shouldPublish { self.lastCaptureDiagnosticPublish = now }
            self.captureDiagnosticLock.unlock()
            if shouldPublish {
                let db = levels.rms > 0 ? 20 * log10(levels.rms) : -90
                let message = "Mic \(String(format: "%+.0f", db)) dB · \(bufferCount) buffers · \(audibleCount) with signal"
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled, self.generation == current else { return }
                    self.onCaptureDiagnostic?(message)
                }
            }
            if prolongedSilence {
                DispatchQueue.main.async { [weak self] in self?.recoverSilentVoiceProcessing(generation: current) }
            }
        }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.enabled, !self.delivered else { return }
                if let result {
                    self.lastRecognitionDiagnostic = result.isFinal ? "recognition result final" : "recognition result partial"
                    self.recognitionErrors = 0
                    let segment = result.bestTranscription.formattedString
                    if self.speaking {
                        guard VoiceInteraction.interruption(segment, spoken: self.spokenText) else {
                            if result.isFinal { self.startSession() }; return
                        }
                        self.interruptedTurn = true
                        self.stopSpeaking(resume: false)
                        self.onInterrupt?()
                    }
                    let text = carry.isEmpty ? segment : carry + " " + segment
                    if text != self.transcript {
                        self.onActivity?()
                        self.transcript = text
                        self.onStatus?(self.wakeMode && !self.conversationWindow.active() ? "Listening for ‘Hey Chef’…" : "Heard: " + text)
                        self.silence?.invalidate()
                        let wakeOnly = self.wakeMode && !self.conversationWindow.active() && WakeGate.decide(text, waitingForRequest: false) == .acknowledge
                        self.silence = Timer.scheduledTimer(withTimeInterval: VoiceInteraction.silenceInterval(wakeOnly: wakeOnly, pauseSeconds: self.pauseSeconds), repeats: false) { [weak self] _ in self?.finishTranscript() }
                    }
                    if result.isFinal {
                        self.startSession(preserving: self.transcript)
                    }
                } else if error != nil {
                    self.recognitionErrors += 1
                    self.lastRecognitionDiagnostic = "recognition error: \(String(error!.localizedDescription.prefix(120)))"
                    if !self.transcript.isEmpty {
                        if self.recognitionErrors < 3 { self.startSession(preserving: self.transcript) } else { self.finishTranscript() }; return
                    }
                    self.lastRecognitionDiagnostic += "; retry scheduled"
                    self.onStatus?(self.runtimeDiagnostic + ". Retrying on-device recognition.")
                    self.stopSession()
                    let delay = VoiceInteraction.retryDelay(consecutiveErrors: self.recognitionErrors)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.enabled, self.generation == current + 1 else { return }
                        self.startSession(preserving: self.transcript)
                    }
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            lastRecognitionDiagnostic = "recognition task started; awaiting audio"
            onListening?(true)
            if !conversationWindow.active() { conversationWindow.end() }
            onStatus?(wakeMode ? (!conversationWindow.active() ? "Listening for ‘Hey Chef’…" : "I'm listening. Say your request—no wake phrase needed.") : "Listening. Speak your request.")
            if !carry.isEmpty {
                let wakeOnly = wakeMode && !conversationWindow.active() && WakeGate.decide(carry, waitingForRequest: false) == .acknowledge
                silence = Timer.scheduledTimer(withTimeInterval: VoiceInteraction.silenceInterval(wakeOnly: wakeOnly, pauseSeconds: pauseSeconds), repeats: false) { [weak self] _ in self?.finishTranscript() }
            }
            sessionLimit = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                guard let self else { return }
                if !self.transcript.isEmpty { self.finishTranscript(); return }
                self.stopSession()
                if self.enabled && (self.wakeMode || self.conversationWindow.active()) { self.startSession() }
                else { self.enabled = false; self.onStatus?("Ready. Press Talk to speak again.") }
            }
        } catch {
            stopSession(); enabled = false; onStatus?("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    private static func audioLevels(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return (0, 0) }
        var sum: Double = 0, peak: Float = 0, count = 0
        if let data = buffer.floatChannelData {
            for channel in 0..<channels { for frame in 0..<frames {
                let value = abs(data[channel][frame]); peak = max(peak, value); sum += Double(value * value); count += 1
            } }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channels { for frame in 0..<frames {
                let value = Float(abs(Int(data[channel][frame]))) / Float(Int16.max); peak = max(peak, value); sum += Double(value * value); count += 1
            } }
        }
        return count == 0 ? (0, peak) : (Float(sqrt(sum / Double(count))), peak)
    }

    private func recoverSilentVoiceProcessing(generation current: Int) {
        guard enabled, generation == current, engine.isRunning, !voiceProcessingFallbackAttempted else { return }
        captureDiagnosticLock.lock()
        voiceProcessingFallbackAttempted = true
        captureDiagnosticLock.unlock()
        lastRecognitionDiagnostic = "capture silent with voice processing; retrying raw input"
        stopSession()
        do { try engine.inputNode.setVoiceProcessingEnabled(false) }
        catch { lastRecognitionDiagnostic = "voice-processing fallback failed: \(error.localizedDescription)" }
        onStatus?(runtimeDiagnostic + ". Retrying microphone capture without voice processing; spoken interruption and echo checks remain active.")
        startSession(preserving: transcript)
    }

    private func finishTranscript() {
        guard !delivered, !transcript.isEmpty else { return }
        var text = transcript
        if interruptedTurn {
            interruptedTurn = false
            if VoiceInteraction.stopOnly(text) { stopSession(); conversationWindow.engage(); if enabled { startSession() }; return }
        }
        if WakeGate.isSleepRequest(text) {
            conversationWindow.end()
            if !wakeMode || WakeGate.shouldDisableMicrophone(text) { enabled = false; onDeactivated?() }
            stopSession()
            let farewell = "I'll be here when you need me."
            onWake?(farewell)
            speak(farewell, allowCloud: true)
            return
        }
        if wakeMode || WakeGate.decide(text, waitingForRequest: false) == .acknowledge {
            let waiting = conversationWindow.active()
            switch WakeGate.decide(text, waitingForRequest: waiting) {
            case .ignore: stopSession(); if enabled { startSession() }; return
            case .acknowledge:
                delivered = true
                conversationWindow.engage()
                stopSession()
                let greeting = acknowledgment.isEmpty || acknowledgment == "Yeah, what's up?" ? Greeting.text() : acknowledgment
                onWake?(greeting)
                speak(greeting, allowCloud: true)
                return
            case .command(let request): text = request
            }
        }
        conversationWindow.engage()
        delivered = true
        stopSession()
        onTranscript?(text)
    }

    private func stopSession() {
        generation += 1
        silence?.invalidate(); silence = nil
        sessionLimit?.invalidate(); sessionLimit = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        onListening?(false)
    }

    func speak(_ text: String, allowCloud: Bool = false, approvedPlanningText: Bool = false) {
        stopSession()
        spokenText = text
        let id = speechTurn.begin()
        activeUtterance = nil
        cloudTask?.cancel(); cloudTask = nil
        cloudPlayer?.stop(); cloudPlayer = nil
        speaker.stopSpeaking(at: .immediate)
        speaking = true
        onSpeaking?(true)
        let fishCandidate = FishFreeVoice.shouldUseFish(text: text, allowCloud: allowCloud, enabled: fishEnabled, consent: fishConsent, approvedPlanningText: approvedPlanningText)
        let key = fishCandidate ? FishCredential.read() : nil
        switch FishFreeVoice.delivery(eligible: allowCloud, privateContent: false, text: text, enabled: fishEnabled, consent: fishConsent, providerReady: key != nil, approvedPlanningText: approvedPlanningText) {
        case .fish:
            onStatus?("Preparing Fish free voice…")
            let voiceID = fishVoiceID
            cloudTask = Task { @MainActor [weak self] in
                do {
                    guard let key else { throw FishFreeVoice.VoiceError.configuration }
                    let data = try await FishFreeVoice.audio(text: text, key: key, voiceID: voiceID)
                    guard let self, !Task.isCancelled, self.speechTurn.active == id else { return }
                    let player = try AVAudioPlayer(data: data)
                    player.delegate = self
                    self.cloudPlayer = player
                    guard player.play() else { throw FishFreeVoice.VoiceError.unavailable }
                    self.onStatus?("Speaking · Fish free voice")
                    if self.enabled { self.startSession() }
                    self.onVoiceNotice?("Fish free voice connected. Public replies use Fish; local and paid fallback are disabled.")
                } catch {
                    guard let self, !Task.isCancelled, self.speechTurn.active == id else { return }
                    self.finishFishWithoutAudio(id, notice: FishFreeVoice.providerFailureNotice(for: .fish) ?? "Fish playback failed. The reply remains on screen.")
                }
            }
        case .textOnly:
            finishFishWithoutAudio(id, notice: "Fish is enabled, but couldn't provide this reply. It remains on screen. Check the saved key, voice ID, or free-window availability, then retry. No local or paid fallback was used.")
        case .privateTextOnly:
            finishFishWithoutAudio(id, notice: FishFreeVoice.privateReplyNotice)
        case .local:
            speakLocally(text)
        }
    }

    private func finishFishWithoutAudio(_ id: Int, notice: String) {
        guard speechTurn.finish(id) else { return }
        activeUtterance = nil; cloudPlayer?.stop(); cloudPlayer = nil; cloudTask = nil
        speaking = false
        onSpeaking?(false)
        onVoiceNotice?(notice)
        if conversationWindow.deadline != nil { conversationWindow.engage() }
        if enabled && (wakeMode || conversationWindow.active()) { startSession() }
        onStatus?(notice)
    }
    private func speakLocally(_ text: String, reason: String? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        activeUtterance = utterance
        utterance.voice = AVSpeechSynthesisVoice(identifier: preferredVoiceID) ?? Self.bestVoice()
        utterance.rate = 0.47
        onStatus?("Speaking · local voice" + (reason.map { " · " + $0 } ?? ""))
        speaker.speak(utterance)
        if enabled { startSession() }
    }
    func stopSpeaking(resume: Bool = true) {
        guard let id = speechTurn.active else { return }
        activeUtterance = nil
        cloudTask?.cancel(); cloudTask = nil
        cloudPlayer?.stop(); cloudPlayer = nil
        speaker.stopSpeaking(at: .immediate)
        finishedSpeaking(id, resume: resume)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeUtterance === utterance, let id = self.speechTurn.active else { return }
            self.finishedSpeaking(id)
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeUtterance === utterance, let id = self.speechTurn.active else { return }
            self.finishedSpeaking(id)
        }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.cloudPlayer === player, let id = self.speechTurn.active else { return }
            if !flag {
                self.finishFishWithoutAudio(id, notice: FishFreeVoice.providerFailureNotice(for: .fish) ?? "Fish playback failed. The reply remains on screen.")
            } else { self.finishedSpeaking(id) }
        }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { audioPlayerDidFinishPlaying(player, successfully: false) }
    private func finishedSpeaking(_ id: Int, resume: Bool = true) {
        guard speechTurn.finish(id) else { return }
        activeUtterance = nil; cloudPlayer = nil; cloudTask = nil
        speaking = false
        onSpeaking?(false)
        if conversationWindow.deadline != nil { conversationWindow.engage() }
        if resume && enabled && (wakeMode || conversationWindow.active()) { startSession() }
        else if resume { onStatus?("Ready. Press Talk to speak again.") }
    }
    func resumeIfNeeded() { if enabled && (wakeMode || conversationWindow.active()) && !speaking { startSession() } }
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        let novelty = ["albert", "bahh", "boing", "bubbles", "cellos", "good news", "bad news", "bells", "jester", "organ", "trinoids", "whisper", "wobble", "zarvox", "hysterical", "deranged"]
        return AVSpeechSynthesisVoice.speechVoices().filter { voice in voice.language.hasPrefix("en") && !novelty.contains(where: { voice.name.lowercased().contains($0) }) }.sorted {
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            let preferred = ["samantha", "daniel", "alex", "ava", "tom", "karen", "serena", "moira"]
            let left = preferred.firstIndex(of: $0.name.lowercased()) ?? 100
            let right = preferred.firstIndex(of: $1.name.lowercased()) ?? 100
            if left != right { return left < right }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        englishVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }
    func chooseVoice(_ id: String) { preferredVoiceID = id; UserDefaults.standard.set(id, forKey: ChefCompatibility.key("ChefVoiceID")) }
    func chooseAcknowledgment(_ text: String) { acknowledgment = text; UserDefaults.standard.set(text, forKey: ChefCompatibility.key("ChefAcknowledgment")) }
}
