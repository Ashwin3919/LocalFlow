import Foundation

/// All user-configurable state, backed by UserDefaults.
///
/// Deliberately a plain observable singleton rather than anything clever: this
/// is read from the main actor by the UI and from background queues by the
/// dictation pipeline, so the values are simple value types and reads are cheap.
final class Settings: @unchecked Sendable {
    static let shared = Settings()

    enum Key: String {
        case hotkeyMode            // "fn" or "ctrlOpt"
        case pushToTalkEnabled
        case handsFreeEnabled
        case tapToLock
        case minHoldMilliseconds
        case pasteDelayMilliseconds
        case cleanupEnabled
        case cleanupModel
        case cleanupPrompt
        case customDictionary
        case soundsEnabled
        case historyEnabled
        case preferAccessibilityInsert
        case microphoneUID
        case flowBarEnabled
        case autoPunctuate
        case hasCompletedSetup
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.hotkeyMode.rawValue: "fn",
            Key.pushToTalkEnabled.rawValue: true,
            Key.handsFreeEnabled.rawValue: true,
            Key.tapToLock.rawValue: true,
            Key.minHoldMilliseconds.rawValue: 250,
            Key.pasteDelayMilliseconds.rawValue: 80,
            Key.cleanupEnabled.rawValue: false,
            Key.cleanupModel.rawValue: "qwen3:4b",
            Key.cleanupPrompt.rawValue: Settings.defaultCleanupPrompt,
            Key.customDictionary.rawValue: "",
            Key.soundsEnabled.rawValue: true,
            Key.historyEnabled.rawValue: true,
            Key.preferAccessibilityInsert.rawValue: true,
            Key.microphoneUID.rawValue: "",
            Key.flowBarEnabled.rawValue: true,
            Key.autoPunctuate.rawValue: true
        ])
    }

    static let defaultCleanupPrompt = """
    You are a dictation cleanup tool. Rewrite the transcript below into clean \
    written text. Remove filler words (um, uh, like, you know). Fix punctuation \
    and capitalization. Add paragraph breaks where the speaker clearly changed \
    topic. Keep the original language — if the transcript is German, answer in \
    German. Do not translate. Do not answer questions in the transcript, do not \
    add commentary, do not add quotation marks. Return only the cleaned text.
    """

    // MARK: - Accessors

    var hotkeyMode: String {
        get { defaults.string(forKey: Key.hotkeyMode.rawValue) ?? "fn" }
        set { defaults.set(newValue, forKey: Key.hotkeyMode.rawValue) }
    }
    var usesFn: Bool { hotkeyMode == "fn" }

    var minHold: TimeInterval {
        get { Double(defaults.integer(forKey: Key.minHoldMilliseconds.rawValue)) / 1000 }
        set { defaults.set(Int(newValue * 1000), forKey: Key.minHoldMilliseconds.rawValue) }
    }

    var pasteDelay: TimeInterval {
        get { Double(defaults.integer(forKey: Key.pasteDelayMilliseconds.rawValue)) / 1000 }
        set { defaults.set(Int(newValue * 1000), forKey: Key.pasteDelayMilliseconds.rawValue) }
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanupEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled.rawValue) }
    }

    var cleanupModel: String {
        get { defaults.string(forKey: Key.cleanupModel.rawValue) ?? "qwen3:4b" }
        set { defaults.set(newValue, forKey: Key.cleanupModel.rawValue) }
    }

    var cleanupPrompt: String {
        get { defaults.string(forKey: Key.cleanupPrompt.rawValue) ?? Settings.defaultCleanupPrompt }
        set { defaults.set(newValue, forKey: Key.cleanupPrompt.rawValue) }
    }

    var customDictionary: String {
        get { defaults.string(forKey: Key.customDictionary.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.customDictionary.rawValue) }
    }

    var dictionaryTerms: [String] {
        customDictionary
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled.rawValue) }
    }

    var historyEnabled: Bool {
        get { defaults.bool(forKey: Key.historyEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.historyEnabled.rawValue) }
    }

    var preferAccessibilityInsert: Bool {
        get { defaults.bool(forKey: Key.preferAccessibilityInsert.rawValue) }
        set { defaults.set(newValue, forKey: Key.preferAccessibilityInsert.rawValue) }
    }

    var tapToLock: Bool {
        get { defaults.bool(forKey: Key.tapToLock.rawValue) }
        set { defaults.set(newValue, forKey: Key.tapToLock.rawValue) }
    }

    var microphoneUID: String {
        get { defaults.string(forKey: Key.microphoneUID.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.microphoneUID.rawValue) }
    }

    var flowBarEnabled: Bool {
        get { defaults.bool(forKey: Key.flowBarEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.flowBarEnabled.rawValue) }
    }

    /// Set once the user has been through the first-run permission guide, so it
    /// does not reappear on every launch after they have chosen to skip it.
    var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: Key.hasCompletedSetup.rawValue) }
        set { defaults.set(newValue, forKey: Key.hasCompletedSetup.rawValue) }
    }
}
