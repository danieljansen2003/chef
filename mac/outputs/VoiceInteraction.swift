import Foundation

enum VoiceInteraction {
    static let silentCaptureFallbackBuffers: UInt64 = 240
    static func shouldRetryRawCapture(bufferCount: UInt64, silentBufferCount: Int, voiceProcessingActive: Bool, fallbackAttempted: Bool) -> Bool {
        voiceProcessingActive && !fallbackAttempted && bufferCount >= silentCaptureFallbackBuffers && silentBufferCount >= Int(silentCaptureFallbackBuffers)
    }
    static func silenceInterval(wakeOnly: Bool, pauseSeconds: Double) -> TimeInterval {
        wakeOnly ? 0.65 : min(15, max(2, pauseSeconds))
    }
    static func retryDelay(consecutiveErrors: Int) -> TimeInterval {
        min(8, pow(2, Double(max(0, consecutiveErrors - 1))))
    }
    static func words(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    static func interruption(_ input: String, spoken: String) -> Bool {
        let tokens = words(input), phrase = tokens.joined(separator: " ")
        guard !tokens.isEmpty else { return false }
        let explicit = ["ok", "okay", "stop", "wait", "chef", "hey chef", "hi chef", "no", "hold on", "that's not", "that is not"]
        guard explicit.contains(where: { phrase == $0 || phrase.hasPrefix($0 + " ") }) else { return false }
        // Never mistake the currently playing assistant's phrase for a human interruption.
        let echo = words(spoken).joined(separator: " ")
        guard phrase.count >= 2, !echo.contains(phrase) else { return false }
        return true
    }
    static func stopOnly(_ text: String) -> Bool { ["ok", "okay", "perfect", "ok perfect", "okay perfect", "stop", "stop talking", "wait", "hold on", "chef"].contains(words(text).joined(separator: " ")) }
    static func speechSummary(_ text: String) -> String {
        if text.contains("```") { return "The code draft is ready on screen. It has not been executed." }
        let clean = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        let words = clean.split(whereSeparator: \.isWhitespace)
        return words.count > 90 ? words.prefix(90).joined(separator: " ") + ". More details are on screen." : clean
    }
    static func test() {
        precondition(!shouldRetryRawCapture(bufferCount: 239, silentBufferCount: 239, voiceProcessingActive: true, fallbackAttempted: false))
        precondition(shouldRetryRawCapture(bufferCount: 240, silentBufferCount: 240, voiceProcessingActive: true, fallbackAttempted: false))
        precondition(!shouldRetryRawCapture(bufferCount: 500, silentBufferCount: 500, voiceProcessingActive: false, fallbackAttempted: false))
        precondition(!shouldRetryRawCapture(bufferCount: 500, silentBufferCount: 500, voiceProcessingActive: true, fallbackAttempted: true))
        precondition(silenceInterval(wakeOnly: true, pauseSeconds: 9) == 0.65)
        precondition(silenceInterval(wakeOnly: false, pauseSeconds: 9) == 9)
        precondition(silenceInterval(wakeOnly: false, pauseSeconds: 99) == 15)
        precondition(retryDelay(consecutiveErrors: 1) == 1)
        precondition(retryDelay(consecutiveErrors: 3) == 4)
        precondition(retryDelay(consecutiveErrors: 9) == 8)
        precondition(interruption("Okay, perfect. I need you to set a timer", spoken: "Your document is ready."))
        precondition(interruption("That is not what I wanted", spoken: "Here is an explanation."))
        precondition(!interruption("okay your document is ready", spoken: "Okay, your document is ready."))
        precondition(!interruption("The document is ready", spoken: "The document is ready."))
        precondition(!interruption("background conversation", spoken: "Different reply"))
        precondition(stopOnly("Okay, perfect.") && !stopOnly("Okay, perfect. Set a timer."))
        precondition(interruption("Hey Chef", spoken: "Your document is ready."))
        precondition(stopOnly("Chef") && stopOnly("Chef"))
        precondition(speechSummary(String(repeating: "word ", count: 200)).split(separator: " ").count <= 100)
        print("Explicit spoken interruption and playback-echo rejection passed. Physical microphone/playback behavior requires acoustic testing.")
    }
}
