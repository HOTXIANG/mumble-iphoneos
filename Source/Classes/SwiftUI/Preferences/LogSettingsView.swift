//
//  LogSettingsView.swift
//  Mumble
//
//  日志设置界面 — 支持全局开关、分类等级控制、文件持久化、日志导出
//

import SwiftUI
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
        Form {
            logSettingsContent
        }
        #if os(iOS)
        .navigationTitle("Logging")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
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
    }

    @ViewBuilder
    private var logSettingsContent: some View {
        // 全局控制
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

        // 文件操作
        if isFilePersistenceEnabled {
            Section(header: Text("Log Files")) {
                let fileWriter = LogManager.shared.fileWriter
                let files = fileWriter.allLogFileURLs

                if files.isEmpty {
                    Text("No log files yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(files, id: \.lastPathComponent) { url in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                            Text(url.lastPathComponent)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
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

        // 分类等级控制
        Section {
            ForEach(LogCategory.allCases, id: \.self) { category in
                categoryRow(category)
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Each category can be individually enabled/disabled and set to a log level. Only messages at or above the set level will be logged.")
        }

        // 环境变量说明
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
    private func categoryRow(_ category: LogCategory) -> some View {
        let enabled = Binding<Bool>(
            get: { categoryStates[category] ?? true },
            set: { newValue in
                categoryStates[category] = newValue
                LogManager.shared.setEnabled(newValue, for: category)
            }
        )

        let level = Binding<LogLevel>(
            get: { categoryLevels[category] ?? .info },
            set: { newValue in
                categoryLevels[category] = newValue
                LogManager.shared.setLevel(newValue, for: category)
            }
        )

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
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // 简单拼接所有日志到一个文件
            var combined = Data()
            for file in files {
                if let data = try? Data(contentsOf: file) {
                    combined.append("=== \(file.lastPathComponent) ===\n".data(using: .utf8)!)
                    combined.append(data)
                    combined.append("\n\n".data(using: .utf8)!)
                }
            }
            try? combined.write(to: url)
        }
        #endif
    }
}
