//
//  LogSettingsView.swift
//  Mumble
//
//  日志设置界面 — 支持全局开关、分类等级控制、文件持久化、日志导出
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct LogSettingsView: View {
    @State private var isGlobalEnabled: Bool = LogManager.shared.isEnabled
    @State private var isFilePersistenceEnabled: Bool = LogManager.shared.isFilePersistenceEnabled
    @State private var categoryStates: [LogCategory: Bool] = [:]
    @State private var categoryLevels: [LogCategory: LogLevel] = [:]
    @State private var showingResetAlert = false
    @State private var showingExportSheet = false

    var body: some View {
        logSettingsBody
            .onAppear {
                AppState.shared.setAutomationCurrentScreen("logSettings")
                loadCurrentState()
            }
            .alert("Reset Logging Settings", isPresented: $showingResetAlert) {
                Button("Reset", role: .destructive) {
                    LogManager.shared.resetToDefaults()
                    loadCurrentState()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All logging categories will be reset to default levels and enabled state.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
                guard let target = notification.userInfo?["target"] as? String else { return }
                if target == "logReset" {
                    showingResetAlert = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
                let target = notification.userInfo?["target"] as? String
                if target == nil || target == "logReset" {
                    showingResetAlert = false
                }
            }
            .onChange(of: showingResetAlert) { _, isPresented in
                if isPresented {
                    AppState.shared.setAutomationPresentedAlert("logReset")
                } else if AppState.shared.automationPresentedAlert == "logReset" {
                    AppState.shared.setAutomationPresentedAlert(nil)
                }
            }
    }

    @ViewBuilder
    private var logSettingsBody: some View {
        #if os(macOS)
        ScrollView {
            Form {
                logSettingsContent
            }
            .formStyle(.grouped)
        }
        #else
        Form {
            logSettingsContent
        }
        .navigationTitle("Logging")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var logSettingsContent: some View {
        #if os(macOS)
        macOSLogSettingsContent
        #else
        iOSLogSettingsContent
        #endif
    }

    // MARK: - macOS (LabeledContent 风格)

    #if os(macOS)
    @ViewBuilder
    private var macOSLogSettingsContent: some View {
        Section {
            LabeledContent("Logging:") {
                Toggle("Enable Logging", isOn: $isGlobalEnabled)
                    .onChange(of: isGlobalEnabled) { _, newValue in
                        LogManager.shared.isEnabled = newValue
                    }
            }
            .padding(.bottom, 2)

            LabeledContent("File Output:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Write Logs to File", isOn: $isFilePersistenceEnabled)
                        .onChange(of: isFilePersistenceEnabled) { _, newValue in
                            LogManager.shared.isFilePersistenceEnabled = newValue
                            NotificationCenter.default.post(name: .muLogFilePersistenceChanged, object: nil)
                        }
                    Text(isFilePersistenceEnabled
                         ? "Log files are stored locally and rotated every 7 days."
                         : "When file logging is off, logs are only available in Console.app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Global")
                .font(.headline)
                .padding(.vertical, 4)
        }

        if isFilePersistenceEnabled {
            Section(header: Text("Log Files").font(.headline).padding(.vertical, 4)) {
                let fileWriter = LogManager.shared.fileWriter
                let files = fileWriter.allLogFileURLs

                if files.isEmpty {
                    LabeledContent("Status:") {
                        Text("No log files yet.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    LabeledContent("Files:") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(files, id: \.lastPathComponent) { url in
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text")
                                            .foregroundColor(.secondary)
                                        Text(url.lastPathComponent)
                                            .font(.system(.body, design: .monospaced))
                                        Text(fileSizeString(url))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }

                    LabeledContent("Export:") {
                        Button {
                            exportLogs()
                        } label: {
                            Label("Export All Logs", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }

        Section {
            ForEach(LogCategory.allCases, id: \.self) { category in
                macOSCategoryRow(category)
            }
        } header: {
            Text("Categories")
                .font(.headline)
                .padding(.vertical, 4)
        } footer: {
            Text("Each category can be individually enabled/disabled and set to a log level.")
        }

        Section(header: Text("Developer").font(.headline).padding(.vertical, 4)) {
            LabeledContent("Environment:") {
                VStack(alignment: .leading, spacing: 6) {
                    labeledCode("MUMBLE_LOG_LEVEL", description: "verbose|debug|info|warning|error")
                    labeledCode("MUMBLE_LOG_DISABLED", description: "audio,plugin,...")
                    labeledCode("MUMBLE_LOG_VERBOSE", description: "connection,network,...")
                    labeledCode("MUMBLE_LOG_FILE", description: "1 (enable file logging)")
                }
            }

            LabeledContent("Reset:") {
                Button("Reset All to Defaults", role: .destructive) {
                    showingResetAlert = true
                }
            }
        }
    }

    @ViewBuilder
    private func macOSCategoryRow(_ category: LogCategory) -> some View {
        let enabled = categoryEnabledBinding(category)
        let level = categoryLevelBinding(category)

        LabeledContent(category.rawValue) {
            HStack(spacing: 12) {
                Toggle("", isOn: enabled)
                    .labelsHidden()
                if categoryStates[category] ?? true {
                    Picker("", selection: level) {
                        ForEach(LogLevel.allCases, id: \.self) { lvl in
                            Text(lvl.label).tag(lvl)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 120)
                }
            }
        }
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    @ViewBuilder
    private var iOSLogSettingsContent: some View {
        Section {
            Toggle("Enable Logging", isOn: $isGlobalEnabled)
                .onChange(of: isGlobalEnabled) { _, newValue in
                    LogManager.shared.isEnabled = newValue
                }

            Toggle("Write Logs to File", isOn: $isFilePersistenceEnabled)
                .onChange(of: isFilePersistenceEnabled) { _, newValue in
                    LogManager.shared.isFilePersistenceEnabled = newValue
                }
        } header: {
            Text("Global")
        } footer: {
            if isFilePersistenceEnabled {
                Text("Log files are stored locally and rotated every 7 days.")
            } else {
                Text("When file logging is off, logs are only available in Console.app.")
            }
        }

        if isFilePersistenceEnabled {
            Section(header: Text("Log Files")) {
                let fileWriter = LogManager.shared.fileWriter
                let files = fileWriter.allLogFileURLs

                if files.isEmpty {
                    Text("No log files yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(files, id: \.lastPathComponent) { url in
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                            Text(url.lastPathComponent)
                                .font(.system(.body, design: .monospaced))
                            Text(fileSizeString(url))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        exportLogs()
                    } label: {
                        Label("Export All Logs", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }

        Section {
            ForEach(LogCategory.allCases, id: \.self) { category in
                iOSCategoryRow(category)
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Each category can be individually enabled/disabled and set to a log level. Only messages at or above the set level will be logged.")
        }

        Section(header: Text("Developer")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Environment Variables")
                    .font(.headline)
                Group {
                    labeledCode("MUMBLE_LOG_LEVEL", description: "verbose|debug|info|warning|error")
                    labeledCode("MUMBLE_LOG_DISABLED", description: "audio,plugin,...")
                    labeledCode("MUMBLE_LOG_VERBOSE", description: "connection,network,...")
                    labeledCode("MUMBLE_LOG_FILE", description: "1 (enable file logging)")
                }
            }
            .padding(.vertical, 4)

            Button("Reset All to Defaults", role: .destructive) {
                showingResetAlert = true
            }
        }
    }

    @ViewBuilder
    private func iOSCategoryRow(_ category: LogCategory) -> some View {
        let enabled = categoryEnabledBinding(category)
        let level = categoryLevelBinding(category)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(category.rawValue, isOn: enabled)
                Spacer()
                if categoryStates[category] ?? true {
                    Picker("", selection: level) {
                        ForEach(LogLevel.allCases, id: \.self) { lvl in
                            Text(lvl.label).tag(lvl)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 120)
                }
            }
        }
    }
    #endif

    // MARK: - Shared Helpers

    private func categoryEnabledBinding(_ category: LogCategory) -> Binding<Bool> {
        Binding<Bool>(
            get: { categoryStates[category] ?? true },
            set: { newValue in
                categoryStates[category] = newValue
                LogManager.shared.setEnabled(newValue, for: category)
            }
        )
    }

    private func categoryLevelBinding(_ category: LogCategory) -> Binding<LogLevel> {
        Binding<LogLevel>(
            get: { categoryLevels[category] ?? .info },
            set: { newValue in
                categoryLevels[category] = newValue
                LogManager.shared.setLevel(newValue, for: category)
            }
        )
    }

    @ViewBuilder
    private func labeledCode(_ key: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.accentColor)
            Text("= \(description)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func loadCurrentState() {
        isGlobalEnabled = LogManager.shared.isEnabled
        isFilePersistenceEnabled = LogManager.shared.isFilePersistenceEnabled
        for category in LogCategory.allCases {
            categoryStates[category] = LogManager.shared.isEnabled(category: category)
            categoryLevels[category] = LogManager.shared.level(for: category)
        }
    }

    private func fileSizeString(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return ""
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    private func exportLogs() {
        let files = LogManager.shared.fileWriter.allLogFileURLs
        guard !files.isEmpty else { return }

        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return }
        let ac = UIActivityViewController(activityItems: files, applicationActivities: nil)
        if let popover = ac.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
        }
        root.present(ac, animated: true)
        #else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mumble-logs.zip"
        panel.allowedContentTypes = [.zip]
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            // 创建临时目录，复制日志文件后用 /usr/bin/ditto 压缩为真正的 zip
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mumble-log-export-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                for file in files {
                    try FileManager.default.copyItem(
                        at: file,
                        to: tmpDir.appendingPathComponent(file.lastPathComponent)
                    )
                }
                // ditto -c -k 创建标准 zip
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", tmpDir.path, destination.path]
                try process.run()
                process.waitUntilExit()
            } catch {
                MumbleLogger.general.error("日志导出失败: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: tmpDir)
        }
        #endif
    }
}
