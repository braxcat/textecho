import SwiftUI

/// Shared model management view — shown from both the Setup Wizard ("Other models") and Settings.
/// Displays all available models with download, delete, and selection capability.
struct ModelPickerView: View {
    @Binding var selectedModel: String
    @Environment(\.dismiss) private var dismiss

    // Download / validate state
    @State private var downloadingModel: String? = nil
    @State private var validatingModels: Set<String> = []
    @State private var downloadedModels: Set<String> = []
    @State private var downloadError: String? = nil

    // Full model list
    @State private var allModels: [String] = []
    @State private var fetchingModels: Bool = true
    @State private var fetchError: String? = nil
    @State private var wkDefaultModel: String = ""
    @State private var wkSupportedModels: Set<String> = []

    private let curatedModels = WhisperKitTranscriber.availableModelList
    private let chipName = WhisperKitTranscriber.currentChipName()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Transcription Models")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = downloadError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                            .padding([.horizontal, .top], 16)
                    }

                    // Curated recommended models
                    sectionHeader("Recommended")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(curatedModels, id: \.name) { model in
                            modelRow(
                                name: model.name,
                                displayName: model.displayName,
                                size: model.size,
                                detail: model.description,
                                wkTag: wkTagFor(model.name)
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                    // All available models
                    Divider().padding(.horizontal, 16).padding(.vertical, 4)

                    if fetchingModels {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading available models...")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    } else if let err = fetchError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(err).font(.system(size: 11)).foregroundColor(.red)
                            Button("Retry") { fetchModels() }
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    } else {
                        let extras = allModels.filter { name in
                            !curatedModels.map(\.name).contains(name)
                        }
                        if !extras.isEmpty {
                            sectionHeader("All available models")
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(extras, id: \.self) { name in
                                    modelRow(
                                        name: name,
                                        displayName: cleanDisplayName(name),
                                        size: sizeFromName(name) ?? "",
                                        detail: nil,
                                        wkTag: wkTagFor(name)
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 620)
        .onAppear {
            checkCacheStatus(for: curatedModels.map(\.name))
            fetchModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: WhisperKitTranscriber.downloadProgressNotification)) { _ in }
    }

    // MARK: - Row views

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func modelRow(name: String, displayName: String, size: String, detail: String?, wkTag: String?) -> some View {
        let isSelected = selectedModel == name
        let isDownloading = downloadingModel == name
        let isValidating = validatingModels.contains(name)
        let isDownloaded = downloadedModels.contains(name)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                // Selection radio
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 16))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.system(size: 12, weight: .semibold))
                        if !size.isEmpty {
                            Text(size)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        if let tag = wkTag {
                            Text(tag)
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(tag.contains("Top pick") ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.12))
                                .foregroundColor(tag.contains("Top pick") ? .orange : .accentColor)
                                .cornerRadius(3)
                        }
                    }
                    if let detail = detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if isDownloading {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .padding(.top, 2)
                        Text("Downloading...")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                // Status / action column
                VStack(alignment: .trailing, spacing: 4) {
                    if isDownloaded {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                            Text("Downloaded").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.green)

                        Button("Delete") {
                            try? WhisperKitTranscriber.deleteModel(name)
                            downloadedModels.remove(name)
                            if selectedModel == name {
                                selectedModel = curatedModels.first?.name ?? selectedModel
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    } else if isValidating {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Validating...").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    } else if !isDownloading {
                        Button("Download") {
                            selectedModel = name
                            startDownload(modelName: name)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(downloadingModel != nil)
                    }
                }
            }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .cornerRadius(7)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.15), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedModel = name
        }
    }

    // MARK: - Logic

    private func wkTagFor(_ name: String) -> String? {
        if name == wkDefaultModel { return "Top pick for \(chipName)" }
        if wkSupportedModels.contains(name) { return "Recommended for \(chipName)" }
        return nil
    }

    private func checkCacheStatus(for modelNames: [String]) {
        for name in modelNames {
            guard WhisperKitTranscriber.isModelCached(name) else { continue }
            guard !downloadedModels.contains(name) && !validatingModels.contains(name) else { continue }
            validatingModels.insert(name)
            Task {
                let isValid = await WhisperKitTranscriber.validateModel(name)
                await MainActor.run {
                    validatingModels.remove(name)
                    if isValid { downloadedModels.insert(name) }
                }
            }
        }
    }

    private func fetchModels() {
        fetchingModels = true
        fetchError = nil
        let recommended = WhisperKitTranscriber.deviceRecommendedModels()
        wkDefaultModel = recommended.defaultModel
        wkSupportedModels = Set(recommended.supportedModels)
        Task {
            do {
                let fetched = try await WhisperKitTranscriber.fetchAllAvailableModels()
                await MainActor.run {
                    allModels = fetched
                    fetchingModels = false
                    checkCacheStatus(for: fetched)
                }
            } catch {
                await MainActor.run {
                    fetchError = "Could not load model list: \(error.localizedDescription)"
                    fetchingModels = false
                }
            }
        }
    }

    private func startDownload(modelName: String) {
        downloadingModel = modelName
        downloadError = nil
        Task {
            let transcriber = WhisperKitTranscriber(
                modelName: modelName,
                idleTimeout: AppConfig.shared.model.whisperIdleTimeout
            )
            do {
                try await transcriber.preload()
            } catch {
                await MainActor.run {
                    downloadingModel = nil
                    downloadError = "Download failed: \(error.localizedDescription)"
                }
                AppLogger.shared.error("Model download failed: \(error)")
                return
            }
            await MainActor.run {
                downloadingModel = nil
                validatingModels.insert(modelName)
            }
            let isValid = await WhisperKitTranscriber.validateModel(modelName)
            await MainActor.run {
                validatingModels.remove(modelName)
                if isValid {
                    downloadedModels.insert(modelName)
                } else {
                    downloadError = "Download completed but validation failed. Try again."
                }
            }
        }
    }

    private func cleanDisplayName(_ name: String) -> String {
        var n = name
        for prefix in ["openai_whisper-", "distil-whisper_"] {
            if n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)); break }
        }
        if let last = n.components(separatedBy: "_").last,
           last.hasSuffix("MB") || last.hasSuffix("GB") {
            n = String(n.dropLast(last.count + 1))
        }
        return n
    }

    private func sizeFromName(_ name: String) -> String? {
        guard let last = name.components(separatedBy: "_").last,
              last.hasSuffix("MB") || last.hasSuffix("GB") else { return nil }
        return last
    }
}
