import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (Foundation Models, macOS 26+) as a zero-download fallback for
/// the core's "shell" backend. It is an instruction-tuned chat model, slower than the
/// built-in engine (about 0.7 s per suggestion warm on an M3 Pro, 2.6 s cold) and without
/// token healing, so it is never picked automatically.
enum AppleModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// The core's request (`{"prefix", "max_words"}`) to a raw continuation. Blocks the
    /// calling (engine) thread for up to 3 s.
    static func complete(_ requestJSON: String) -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable,
              let o = try? JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any],
              let prefix = o["prefix"] as? String else { return nil }
        let words = (o["max_words"] as? Int) ?? 4
        let done = DispatchSemaphore(value: 0)
        var reply: String?
        Task.detached(priority: .userInitiated) {
            // A fresh session each time: a long-lived one would carry earlier turns.
            let session = LanguageModelSession(instructions: """
                You continue the user's text exactly where it stops. Reply with only the next \
                \(words) words or fewer, with no quotes, notes or explanation.
                """)
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: words * 4 + 8)
            reply = try? await session.respond(to: "Continue this text:\n\n" + prefix, options: options).content
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success, var text = reply else { return nil }
        text = text.trimmingCharacters(in: .newlines)
        // The model starts its reply without the space a continuation needs.
        if let first = text.first, first.isLetter || first.isNumber, let last = prefix.last, !last.isWhitespace {
            text = " " + text
        }
        return text
        #else
        return nil
        #endif
    }
}
