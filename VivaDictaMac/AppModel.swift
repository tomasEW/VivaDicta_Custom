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

    @Published var backend: Backend {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "transcriptionBackend") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "transcriptionLanguage") }
    }
    @Published var autoInsert: Bool {
        didSet { UserDefaults.standard.set(autoInsert, forKey: "autoInsert") }
    }
    @Published var groqAPIKey: String
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isDownloadingLocalModel = false
    @Published private(set) var localModelProgress: Double = 0
    @Published private(set) var localModelStatus = ""
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

    func toggleRecording(captureTarget: Bool = false) {
        guard !isProcessing, !isDownloadingLocalModel else { return }
        if isRecording {
            stopAndTranscribe()
        } else {
            Task { await startRecording(captureTarget: captureTarget) }
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
        statusText = "已複製到剪貼簿"
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

                transcript = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else {
                    statusText = "沒有辨識到文字"
                    return
                }

                if autoInsert, let targetPID {
                    let inserted = await TextInserter.insert(transcript, into: targetPID, promptForAccessibility: true)
                    statusText = inserted ? "轉錄完成並已貼入" : "轉錄完成；已複製到剪貼簿"
                } else {
                    statusText = "轉錄完成"
                }
            } catch {
                errorText = "轉錄失敗：\(error.localizedDescription)"
                statusText = "轉錄失敗"
            }
        }
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
