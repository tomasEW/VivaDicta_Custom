import AppKit
import AVFoundation
import AudioRecording
import CloudTranscription
import Keychain
import LocalTranscription

@MainActor
final class AppModel: ObservableObject {
    enum Backend: String, CaseIterable, Identifiable {
        case groq = "Groq"
        case local = "本地 WhisperKit"

        var id: String { rawValue }
    }

    enum APIKeyStorageState: Equatable {
        case missing
        case unsaved
        case saved
        case failed
    }

    private enum RecordingWorkflow {
        case dictation
        case speakToEdit(TextSelectionContext)
    }

    static let localModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let groqModelName = "whisper-large-v3-turbo"
    static let defaultRefinementModel = "openai/gpt-oss-20b"
    static let defaultRefinementPrompt = """
    你是語音轉文字後處理器。請只修正使用者提供的逐字稿，不要回答內容本身。

    規則：
    1. 保留原意、語氣、資訊與專有名詞，不新增不存在的事實。
    2. 修正明顯的語音辨識錯字、同音字、斷句與標點。
    3. 中文以自然的繁體中文書寫；英文產品名、技術名詞、縮寫與指令維持英文。
    4. 移除沒有語意作用的口頭填充詞與不必要重複，但不要把內容大幅摘要或改寫。
    5. 不要加入標題、說明、引號、前言或結語。
    6. 只輸出修正後的文字。
    """

    static let speakToEditSystemPrompt = """
    你是文字編輯器，不是聊天機器人。使用者會提供一段「目前選取的原文」以及一段由語音辨識得到的「修改指令」。

    你的工作只有一件事：依照修改指令改寫原文，並輸出修改完成後的完整文字。

    規則：
    1. 修改指令是操作命令，不是要你回答的問題。即使指令看起來像問題，也不要回答它。
    2. 除非指令要求，否則保留原文的事實、語意、專有名詞、數字與重要細節。
    3. 可以依指令做正式化、口語化、縮短、擴寫、翻譯、重組、修正文法或改變語氣。
    4. 不要加入說明、前言、標題、引號、註解或「修改後如下」之類的文字。
    5. 只輸出改寫後的完整文字，讓它可以直接取代目前選取的原文。
    """

    @Published var backend: Backend {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "transcriptionBackend") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "transcriptionLanguage") }
    }
    @Published var autoInsert: Bool {
        didSet { UserDefaults.standard.set(autoInsert, forKey: "autoInsert") }
    }
    @Published var refinementEnabled: Bool {
        didSet { UserDefaults.standard.set(refinementEnabled, forKey: "refinementEnabled") }
    }
    @Published var refinementModel: String {
        didSet { UserDefaults.standard.set(refinementModel, forKey: "refinementModel") }
    }
    @Published var refinementPrompt: String {
        didSet { UserDefaults.standard.set(refinementPrompt, forKey: "refinementPrompt") }
    }
    @Published var groqAPIKey: String {
        didSet {
            let trimmed = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                groqAPIKeyStorageState = .missing
            } else if trimmed == savedGroqAPIKey {
                groqAPIKeyStorageState = .saved
            } else {
                groqAPIKeyStorageState = .unsaved
            }
        }
    }
    @Published private(set) var groqAPIKeyStorageState: APIKeyStorageState = .missing
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isRefining = false
    @Published private(set) var isSpeakToEditActive = false
    @Published private(set) var isDownloadingLocalModel = false
    @Published private(set) var localModelProgress: Double = 0
    @Published private(set) var localModelStatus = ""
    @Published var rawTranscript = ""
    @Published var transcript = ""
    @Published private(set) var speakToEditSourceText = ""
    @Published private(set) var speakToEditInstruction = ""
    @Published private(set) var speakToEditResult = ""
    @Published private(set) var statusText = "準備就緒"
    @Published private(set) var errorText: String?

    private let recorder = DefaultAudioRecordingService()
    private let keychain = DefaultKeychainService(service: "com.tomasew.VivaDictaMac")
    private let localTranscriber = WhisperKitTranscriptionService()
    private var hotKey: GlobalHotKey?
    private var recordingURL: URL?
    private var targetPID: pid_t?
    private var recordingWorkflow: RecordingWorkflow = .dictation
    private var savedGroqAPIKey = ""

    private let groqKeychainKey = "groq_api_key"

    init() {
        let defaults = UserDefaults.standard
        backend = Backend(rawValue: defaults.string(forKey: "transcriptionBackend") ?? "") ?? .groq
        language = defaults.string(forKey: "transcriptionLanguage") ?? "auto"
        autoInsert = defaults.object(forKey: "autoInsert") as? Bool ?? true
        refinementEnabled = defaults.object(forKey: "refinementEnabled") as? Bool ?? false
        refinementModel = defaults.string(forKey: "refinementModel") ?? Self.defaultRefinementModel
        refinementPrompt = defaults.string(forKey: "refinementPrompt") ?? Self.defaultRefinementPrompt
        let storedGroqAPIKey = keychain.getString(forKey: groqKeychainKey, syncable: false) ?? ""
        groqAPIKey = storedGroqAPIKey
        savedGroqAPIKey = storedGroqAPIKey
        groqAPIKeyStorageState = storedGroqAPIKey.isEmpty ? .missing : .saved

        recorder.onDidFinishUnsuccessfully = { [weak self] in
            self?.isRecording = false
            self?.isSpeakToEditActive = false
            self?.recordingWorkflow = .dictation
            self?.recordingURL = nil
            self?.statusText = "錄音失敗"
            self?.errorText = "系統回報錄音未成功完成。"
        }

        hotKey = GlobalHotKey(
            dictationCallback: { [weak self] in
                self?.toggleRecording(captureTarget: true)
            },
            speakToEditCallback: { [weak self] in
                self?.toggleSpeakToEdit()
            }
        )
    }

    var isLocalModelReady: Bool {
        WhisperKitModelPath.isDownloaded(modelName: Self.localModelName)
    }

    var hotKeyIsRegistered: Bool {
        hotKey?.isRegistered ?? false
    }

    var dictationHotKeyIsRegistered: Bool {
        hotKey?.dictationIsRegistered ?? false
    }

    var speakToEditHotKeyIsRegistered: Bool {
        hotKey?.speakToEditIsRegistered ?? false
    }

    func saveGroqAPIKey() {
        let trimmed = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        groqAPIKey = trimmed
        guard !trimmed.isEmpty else {
            if keychain.delete(forKey: groqKeychainKey, syncable: false) {
                savedGroqAPIKey = ""
                groqAPIKeyStorageState = .missing
                statusText = "已清除 Groq API Key"
                errorText = nil
            } else {
                groqAPIKeyStorageState = .failed
                errorText = "無法從 macOS Keychain 清除 Groq API Key。"
            }
            return
        }
        if keychain.save(trimmed, forKey: groqKeychainKey, syncable: false) {
            savedGroqAPIKey = trimmed
            groqAPIKeyStorageState = .saved
            statusText = "Groq API Key 已安全儲存"
            errorText = nil
        } else {
            groqAPIKeyStorageState = .failed
            errorText = "無法將 Groq API Key 寫入 macOS Keychain。"
        }
    }

    func resetRefinementPrompt() {
        refinementPrompt = Self.defaultRefinementPrompt
        refinementModel = Self.defaultRefinementModel
        statusText = "已恢復預設精練設定"
    }

    func toggleRecording(captureTarget: Bool = false) {
        guard !isProcessing, !isDownloadingLocalModel else { return }
        if isRecording {
            stopAndTranscribe()
        } else {
            Task { await startRecording(captureTarget: captureTarget, workflow: .dictation) }
        }
    }

    func toggleSpeakToEdit() {
        guard !isProcessing, !isDownloadingLocalModel else { return }

        if isRecording {
            stopAndTranscribe()
            return
        }

        guard !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "Speak to Edit 需要 Groq API Key 來執行 AI 改寫。"
            statusText = "Speak to Edit 缺少 Groq API Key"
            revealMainWindowForHotKeyError()
            return
        }

        guard let selection = TextInserter.captureSelection(promptForAccessibility: true) else {
            errorText = "沒有讀到選取文字。請先在其他 App 明確選取一段可編輯文字，再按 ⌃⌥E。"
            statusText = "Speak to Edit：沒有選取文字"
            revealMainWindowForHotKeyError()
            return
        }

        speakToEditSourceText = selection.selectedText
        speakToEditInstruction = ""
        speakToEditResult = ""
        errorText = nil

        Task {
            await startRecording(captureTarget: false, workflow: .speakToEdit(selection))
        }
    }

    func refineCurrentTranscript() {
        let source = rawTranscript.isEmpty ? transcript : rawTranscript
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "精練需要 Groq API Key。"
            return
        }
        guard !isRefining else { return }

        isRefining = true
        statusText = "AI 精練中…"
        errorText = nil
        Task {
            defer { isRefining = false }
            do {
                transcript = try await refineTranscript(source)
                statusText = "精練完成"
            } catch {
                errorText = "精練失敗：\(error.localizedDescription)"
                statusText = "精練失敗；保留原始文字"
            }
        }
    }

    func insertTranscriptNow() {
        guard !transcript.isEmpty else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task {
            let inserted = await TextInserter.insert(transcript, into: pid, promptForAccessibility: true)
            statusText = inserted ? "已貼入目前 App" : "已複製到剪貼簿；請允許輔助使用權限後再試"
        }
    }

    func copyTranscript() {
        TextInserter.copy(transcript)
        statusText = "已複製最後輸出"
    }

    func copyRawTranscript() {
        TextInserter.copy(rawTranscript)
        statusText = "已複製原始 ASR 文字"
    }

    func downloadLocalModel() {
        guard !isDownloadingLocalModel, !isLocalModelReady else { return }
        isDownloadingLocalModel = true
        localModelProgress = 0
        localModelStatus = "準備下載…"
        errorText = nil

        Task {
            do {
                try await LocalModelDownloader.downloadAndPrepareWhisperKit(modelName: Self.localModelName) { [weak self] phase in
                    Task { @MainActor in
                        guard let self else { return }
                        switch phase {
                        case .downloading(let fractionCompleted):
                            self.localModelProgress = fractionCompleted * 0.82
                            self.localModelStatus = "下載模型 \(Int(fractionCompleted * 100))%"
                        case .prewarmStart:
                            self.localModelProgress = 0.86
                            self.localModelStatus = "最佳化 Core ML 模型…"
                        case .loadStart:
                            self.localModelProgress = 0.95
                            self.localModelStatus = "驗證模型…"
                        case .finished:
                            self.localModelProgress = 1
                            self.localModelStatus = "本地模型已就緒"
                        }
                    }
                }
                isDownloadingLocalModel = false
                localModelProgress = 1
                localModelStatus = "本地模型已就緒"
                statusText = "本地 WhisperKit 已可使用"
            } catch {
                isDownloadingLocalModel = false
                localModelStatus = "下載失敗"
                errorText = "本地模型下載或準備失敗：\(error.localizedDescription)"
            }
        }
    }

    func requestAccessibilityPermission() {
        _ = TextInserter.isAccessibilityTrusted(prompt: true)
    }

    private func startRecording(
        captureTarget: Bool,
        workflow: RecordingWorkflow
    ) async {
        errorText = nil
        guard await microphoneAccessGranted() else {
            errorText = "需要麥克風權限。請到「系統設定 → 隱私權與安全性 → 麥克風」允許 VivaDicta Mac。"
            statusText = "沒有麥克風權限"
            if captureTarget { revealMainWindowForHotKeyError() }
            return
        }

        if backend == .groq && groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorText = "請先輸入並儲存 Groq API Key。"
            statusText = "缺少 Groq API Key"
            if captureTarget { revealMainWindowForHotKeyError() }
            return
        }

        let speakToEditRequested: Bool
        switch workflow {
        case .dictation:
            speakToEditRequested = false
        case .speakToEdit:
            speakToEditRequested = true
        }

        if (refinementEnabled || speakToEditRequested) && groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorText = speakToEditRequested
                ? "Speak to Edit 需要 Groq API Key。"
                : "已啟用 AI 精練，請先輸入並儲存 Groq API Key。"
            statusText = speakToEditRequested ? "Speak to Edit 缺少 Groq API Key" : "精練缺少 Groq API Key"
            if captureTarget || speakToEditRequested { revealMainWindowForHotKeyError() }
            return
        }

        if backend == .local && !isLocalModelReady {
            errorText = "本地模型尚未下載。請先按「下載本地模型」。"
            statusText = "本地模型尚未下載"
            if captureTarget { revealMainWindowForHotKeyError() }
            return
        }

        recordingWorkflow = workflow
        isSpeakToEditActive = speakToEditRequested

        switch workflow {
        case .speakToEdit(let context):
            targetPID = context.targetPID
        case .dictation:
            if captureTarget {
                let frontmost = NSWorkspace.shared.frontmostApplication
                if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    targetPID = frontmost?.processIdentifier
                } else {
                    targetPID = nil
                }
            } else {
                targetPID = nil
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VivaDictaMac-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            try recorder.startRecording(to: url, settings: settings)
            recordingURL = url
            isRecording = true
            statusText = speakToEditRequested
                ? "Speak to Edit 錄音中… 再按 ⌃⌥E 停止"
                : "錄音中… 再按 ⌃⌥Space 停止"
        } catch {
            recordingWorkflow = .dictation
            isSpeakToEditActive = false
            recordingURL = nil
            errorText = "無法開始錄音：\(error.localizedDescription)"
            statusText = "錄音啟動失敗"
        }
    }

    private func stopAndTranscribe() {
        guard let audioURL = recorder.stopRecording() ?? recordingURL else {
            isRecording = false
            isSpeakToEditActive = false
            recordingWorkflow = .dictation
            statusText = "沒有可轉錄的錄音"
            return
        }

        let workflow = recordingWorkflow
        recordingWorkflow = .dictation
        isRecording = false
        isSpeakToEditActive = false
        recordingURL = nil
        isProcessing = true

        switch workflow {
        case .dictation:
            statusText = backend == .groq ? "Groq 轉錄中…" : "本地轉錄中…"
        case .speakToEdit:
            statusText = "辨識 Speak to Edit 指令中…"
        }
        errorText = nil

        Task {
            defer {
                isProcessing = false
                try? FileManager.default.removeItem(at: audioURL)
            }

            do {
                let resultText: String
                switch backend {
                case .groq:
                    let service = GroqTranscriptionService(
                        config: .init(
                            apiKey: groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            modelName: Self.groqModelName,
                            language: language
                        )
                    )
                    resultText = try await service.transcribe(audioURL: audioURL).text

                case .local:
                    let options = WhisperKitTranscriptionService.Options(
                        language: language,
                        isVADEnabled: true,
                        isSpeakerDiarizationEnabled: false
                    )
                    resultText = try await localTranscriber.transcribe(
                        audioURL: audioURL,
                        modelName: Self.localModelName,
                        displayName: "Whisper Large V3 Turbo 632MB",
                        options: options
                    ).text
                }

                rawTranscript = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
                transcript = rawTranscript
                guard !rawTranscript.isEmpty else {
                    switch workflow {
                    case .dictation:
                        statusText = "沒有辨識到文字"
                    case .speakToEdit:
                        statusText = "沒有辨識到編輯指令"
                    }
                    return
                }

                if case .speakToEdit(let context) = workflow {
                    speakToEditInstruction = rawTranscript
                    statusText = "指令已辨識，AI 改寫選取文字中…"
                    isRefining = true

                    do {
                        let editedText = try await applyVoiceInstruction(
                            instruction: rawTranscript,
                            to: context.selectedText
                        )
                        transcript = editedText
                        speakToEditResult = editedText
                        isRefining = false

                        let replaced = await TextInserter.replaceSelection(
                            with: editedText,
                            context: context,
                            promptForAccessibility: true
                        )

                        if replaced {
                            statusText = "Speak to Edit 完成，已取代原本選取文字"
                        } else {
                            statusText = "改寫完成，但選取位置已改變；結果已複製到剪貼簿"
                            errorText = "為避免改到錯誤位置，VivaDicta 沒有自動貼入。請確認原選取文字仍在原位置後手動貼上。"
                        }
                    } catch {
                        isRefining = false
                        transcript = context.selectedText
                        speakToEditResult = ""
                        errorText = "Speak to Edit 失敗：\(error.localizedDescription)"
                        statusText = "Speak to Edit 失敗；原文未變更"
                    }
                    return
                }

                if refinementEnabled {
                    statusText = "ASR 完成，AI 精練中…"
                    isRefining = true
                    do {
                        transcript = try await refineTranscript(rawTranscript)
                    } catch {
                        transcript = rawTranscript
                        errorText = "精練失敗，已保留原始 ASR 文字：\(error.localizedDescription)"
                    }
                    isRefining = false
                }

                if autoInsert, let targetPID {
                    let inserted = await TextInserter.insert(transcript, into: targetPID, promptForAccessibility: true)
                    if inserted {
                        statusText = refinementEnabled ? "轉錄、精練完成並已貼入" : "轉錄完成並已貼入"
                    } else {
                        statusText = refinementEnabled ? "轉錄、精練完成；已複製到剪貼簿" : "轉錄完成；已複製到剪貼簿"
                    }
                } else {
                    statusText = refinementEnabled ? "轉錄與精練完成" : "轉錄完成"
                }
            } catch {
                isRefining = false
                errorText = "轉錄失敗：\(error.localizedDescription)"
                statusText = "轉錄失敗"
            }
        }
    }

    private func refineTranscript(_ text: String) async throws -> String {
        try await performGroqTextTask(
            systemPrompt: refinementPrompt,
            userMessage: text
        )
    }

    private func applyVoiceInstruction(
        instruction: String,
        to targetText: String
    ) async throws -> String {
        let message = """
        <CURRENTLY_SELECTED_TEXT>
        \(targetText)
        </CURRENTLY_SELECTED_TEXT>

        <SPOKEN_EDIT_INSTRUCTION>
        \(instruction)
        </SPOKEN_EDIT_INSTRUCTION>
        """

        return try await performGroqTextTask(
            systemPrompt: Self.speakToEditSystemPrompt,
            userMessage: message
        )
    }

    private func performGroqTextTask(
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        let key = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RefinementError.missingAPIKey }

        let model = refinementModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw RefinementError.missingModel }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw RefinementError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RefinementRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userMessage)
            ],
            maxCompletionTokens: 4096
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RefinementError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? JSONDecoder().decode(GroqErrorEnvelope.self, from: data)
            throw RefinementError.apiError(apiError?.error.message ?? "HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(RefinementResponse.self, from: data)
        guard let output = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            throw RefinementError.emptyOutput
        }
        return output
    }

    private func revealMainWindowForHotKeyError() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let window = NSApplication.shared.windows.first { $0.title == "VivaDicta Mac" }
            ?? NSApplication.shared.windows.first { $0.canBecomeMain }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

private struct RefinementRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let maxCompletionTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxCompletionTokens = "max_completion_tokens"
    }
}

private struct RefinementResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct GroqErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }
    let error: APIError
}

private enum RefinementError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidResponse
    case emptyOutput
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "缺少 Groq API Key"
        case .missingModel: "沒有設定 AI 模型"
        case .invalidResponse: "Groq 回應格式無效"
        case .emptyOutput: "AI 模型沒有回傳文字"
        case .apiError(let message): "Groq API：\(message)"
        }
    }
}
