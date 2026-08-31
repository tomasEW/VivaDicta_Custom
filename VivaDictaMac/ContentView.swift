import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                backendSection
                languageSection
                refinementSection
                recordingSection
                transcriptSection
                statusSection
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.system(size: 42))
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text("VivaDicta Mac")
                    .font(.title2.bold())
                Text("⌃⌥Space：在任何 App 開始／停止語音輸入")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var backendSection: some View {
        GroupBox("轉錄方式") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("後端", selection: $model.backend) {
                    ForEach(AppModel.Backend.allCases) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                if model.backend == .groq {
                    HStack {
                        SecureField("Groq API Key（gsk_…）", text: $model.groqAPIKey)
                            .textFieldStyle(.roundedBorder)
                        Button("儲存") { model.saveGroqAPIKey() }
                    }
                    Text("ASR 預設使用 whisper-large-v3-turbo；同一把 Groq API Key 也可供 AI 精練使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: model.isLocalModelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                            Text(model.isLocalModelReady ? "Whisper Large V3 Turbo 632MB 已就緒" : "Whisper Large V3 Turbo 632MB 尚未下載")
                            Spacer()
                            if !model.isLocalModelReady {
                                Button(model.isDownloadingLocalModel ? "下載中…" : "下載本地模型") {
                                    model.downloadLocalModel()
                                }
                                .disabled(model.isDownloadingLocalModel)
                            }
                        }

                        if model.isDownloadingLocalModel || model.localModelProgress > 0 {
                            ProgressView(value: model.localModelProgress)
                            if !model.localModelStatus.isEmpty {
                                Text(model.localModelStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var languageSection: some View {
        GroupBox("語言") {
            HStack {
                Picker("辨識語言", selection: $model.language) {
                    Text("自動偵測").tag("auto")
                    Text("繁體中文 / 中文").tag("zh")
                    Text("English").tag("en")
                }
                .frame(width: 260)
                Spacer()
                Toggle("完成後自動貼回原本 App", isOn: $model.autoInsert)
            }
            .padding(8)
        }
    }

    private var refinementSection: some View {
        GroupBox("AI 精練") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("ASR 後自動精練文字", isOn: $model.refinementEnabled)

                HStack {
                    Text("Groq 模型")
                    TextField("openai/gpt-oss-20b", text: $model.refinementModel)
                        .textFieldStyle(.roundedBorder)
                    Button("恢復預設") { model.resetRefinementPrompt() }
                }

                Text("精練 Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.refinementPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 145)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                Text("精練失敗時會保留並輸出原始 ASR，不會因 AI 失敗而吃掉轉錄結果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var recordingSection: some View {
        VStack(spacing: 10) {
            Button {
                model.toggleRecording()
            } label: {
                Label(
                    model.isRecording ? "停止並轉錄" : (model.isProcessing ? "處理中…" : "開始錄音"),
                    systemImage: model.isRecording ? "stop.circle.fill" : "mic.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isProcessing || model.isDownloadingLocalModel)

            if model.isProcessing || model.isRefining {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(spacing: 14) {
            GroupBox("原始 ASR") {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $model.rawTranscript)
                        .font(.body)
                        .frame(minHeight: 105)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("保留未精練版本，方便比較 ASR 與 AI 後處理差異。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("複製 Raw") { model.copyRawTranscript() }
                            .disabled(model.rawTranscript.isEmpty)
                        Button(model.isRefining ? "精練中…" : "重新精練") { model.refineCurrentTranscript() }
                            .disabled(model.rawTranscript.isEmpty || model.isRefining)
                    }
                }
                .padding(8)
            }

            GroupBox("最後輸出") {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $model.transcript)
                        .font(.body)
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Button("要求輔助使用權限") { model.requestAccessibilityPermission() }
                        Spacer()
                        Button("複製") { model.copyTranscript() }
                            .disabled(model.transcript.isEmpty)
                        Button("貼到目前 App") { model.insertTranscriptNow() }
                            .disabled(model.transcript.isEmpty)
                    }
                }
                .padding(8)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .frame(width: 8, height: 8)
                    .foregroundStyle(model.errorText == nil ? .green : .red)
                Text(model.statusText)
                    .font(.callout)
            }
            if let error = model.errorText {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !model.hotKeyIsRegistered {
                Text("全域快捷鍵註冊失敗；仍可用視窗中的錄音按鈕。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button(model.isRecording ? "停止並轉錄" : "開始錄音") {
            model.toggleRecording()
        }
        .disabled(model.isProcessing || model.isDownloadingLocalModel)

        Text(model.statusText)
        Divider()
        SettingsLink { Text("設定…") }
        Button("結束 VivaDicta Mac") { NSApp.terminate(nil) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker("轉錄後端", selection: $model.backend) {
                ForEach(AppModel.Backend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }

            Picker("語言", selection: $model.language) {
                Text("自動偵測").tag("auto")
                Text("中文").tag("zh")
                Text("English").tag("en")
            }

            Toggle("全域快捷鍵完成後自動貼回", isOn: $model.autoInsert)
            Toggle("ASR 後使用 Groq AI 精練", isOn: $model.refinementEnabled)

            if model.backend == .groq || model.refinementEnabled {
                SecureField("Groq API Key", text: $model.groqAPIKey)
                Button("儲存 Groq API Key") { model.saveGroqAPIKey() }
            }

            if model.refinementEnabled {
                TextField("精練模型", text: $model.refinementModel)
                Button("恢復預設精練設定") { model.resetRefinementPrompt() }
            }

            if model.backend == .local {
                LabeledContent("本地模型", value: model.isLocalModelReady ? "已就緒" : "尚未下載")
                if !model.isLocalModelReady {
                    Button("下載 Whisper Large V3 Turbo 632MB") { model.downloadLocalModel() }
                        .disabled(model.isDownloadingLocalModel)
                }
            }

            LabeledContent("全域快捷鍵", value: "⌃⌥Space")
            Button("要求輔助使用權限") { model.requestAccessibilityPermission() }
        }
        .padding(24)
    }
}
