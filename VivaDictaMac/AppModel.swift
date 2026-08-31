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
    @Published var groqAPIKey: String
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isRefining = false
    @Published private(set) var isDownloadingLocalModel = false
    @Published private(set) var localModelProgress: Double = 0
    @Published private(set) var localModelStatus = ""
    @Published var rawTranscript = ""
    @Published var transcript = ""
    @Published private(set) var statusText = "準備就緒"
    @Published private(set) var errorText: String?

    private let recorder = DefaultAudioRecordingService()
    private let keychain = DefaultKeychainService(service: "com.tomasew.VivaDictaMac")
    private let localTranscriber = WhisperKitTranscriptionService()
    private var hotKey: GlobalHotKey?
    private var recordingURL: URL?
    private var targetPID: pid_t?

    private let groqKeychainKey = "groq_api_key"

    init() {
        let defaults = UserDefaults.standard
        backend = Backend(rawValue: defaults.string(forKey: "transcriptionBackend") ?? "") ?? .groq
        language = defaults.string(forKey: "transcriptionLanguage") ?? "auto"
        autoInsert = defaults.object(forKey: "autoInsert") as? Bool ?? true
        refinementEnabled = defaults.object(forKey: "refinementEnabled") as? Bool ?? false
        refinementModel = defaults.string(forKey: "refinementModel") ?? Self.defaultRefinementModel
        refinementPrompt = defaults.string(forKey: "refinementPrompt") ?? Self.defaultRefinementPrompt
        groqAPIKey = keychain.getString(forKey: groqKeychainKey, syncable: false) ?? ""

        recorder.onDidFinishUnsuccessfully = { [weak self] in
            self?.isRecording = false
            self?.recordingURL = nil
            self?.statusText = "錄音失敗"
            self?.errorText = "系統回報錄音未成功完成。"
        }

        hotKey = GlobalHotKey { [weak self] in
            self?.toggleRecording(captureTarget: true)
        }
    }

    var isLocalModelReady: Bool {
        WhisperKitModelPath.isDownloaded(modelName: Self.localModelName)
    }

    var hotKeyIsRegistered: Bool {
        hotKey?.isRegistered ?? false
    }

    func saveGroqAPIKey() {
        let trimmed = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        groqAPIKey = trimmed
        guard !trimmed.isEmpty else {
            _ = keychain.delete(forKey: groqKeychainKey, syncable: false)
            statusText = "已清除 Groq API Key"
            return
        }
        if keychain.save(trimmed, forKey: groqKeychainKey, syncable: false) {
            statusText = "Groq API Key 已安全儲存"
            errorText = nil
        } else {
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
            Task { await startRecording(captureTarget: captureTarget) }
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

    private func startRecording(captureTarget: Bool) async {
        errorText = nil
        guard await microphoneAccessGranted() else {
            errorText = "需要麥克風權限。請到「系統設定 → 隱私權與安全性 → 麥克風」允許 VivaDicta Mac。"
            statusText = "沒有麥克風權限"
            return
        }

        if backend == .groq && groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorText = "請先輸入並儲存 Groq API Key。"
            statusText = "缺少 Groq API Key"
            return
        }

        if refinementEnabled && groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorText = "已啟用 AI 精練，請先輸入並儲存 Groq API Key。"
            statusText = "精練缺少 Groq API Key"
            return
        }

        if backend == .local && !isLocalModelReady {
            errorText = "本地模型尚未下載。請先按「下載本地模型」。"
            statusText = "本地模型尚未下載"
            return
        }

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
            statusText = "錄音中… 再按 ⌃⌥Space 停止"
        } catch {
            recordingURL = nil
            errorText = "無法開始錄音：\(error.localizedDescription)"
            statusText = "錄音啟動失敗"
        }
    }

    private func stopAndTranscribe() {
        guard let audioURL = recorder.stopRecording() ?? recordingURL else {
            isRecording = false
            statusText = "沒有可轉錄的錄音"
            return
        }

        isRecording = false
        recordingURL = nil
        isProcessing = true
        statusText = backend == .groq ? "Groq 轉錄中…" : "本地轉錄中…"
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
                    statusText = "沒有辨識到文字"
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
                .init(role: "system", content: refinementPrompt),
                .init(role: "user", content: text)
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
        case .missingModel: "沒有設定精練模型"
        case .invalidResponse: "Groq 回應格式無效"
        case .emptyOutput: "精練模型沒有回傳文字"
        case .apiError(let message): "Groq API：\(message)"
        }
    }
}
