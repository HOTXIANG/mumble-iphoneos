//
//  LogCategories.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//  Updated: 统一日志系统 — LogLevel / LogCategory / LogManager / LogProxy
//

import Foundation
import OSLog

extension Notification.Name {
    static let mumbleLogEntryAdded = Notification.Name("MumbleLogEntryAdded")
}

private struct RecentLogEntry: Sendable {
    let timestamp: String
    let category: String
    let level: String
    let levelRaw: Int
    let symbol: String
    let message: String
    let file: String
    let function: String
    let line: Int

    var dictionary: [String: Any] {
        [
            "timestamp": timestamp,
            "category": category,
            "level": level,
            "levelRaw": levelRaw,
            "symbol": symbol,
            "message": message,
            "file": file,
            "function": function,
            "line": line
        ]
    }
}

// MARK: - Log Level

/// 日志等级，从高到低：error > warning > info > debug > verbose
/// 设定某等级后，只输出该等级及以上的日志
enum LogLevel: Int, Comparable, CaseIterable, Codable, Sendable {
    case verbose = 0
    case debug   = 1
    case info    = 2
    case warning = 3
    case error   = 4

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var osLogType: OSLogType {
        switch self {
        case .verbose: return .debug
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        }
    }

    var label: String {
        switch self {
        case .verbose: return "VERBOSE"
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARNING"
        case .error:   return "ERROR"
        }
    }

    var apiValue: String {
        switch self {
        case .verbose: return "verbose"
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    var symbol: String {
        switch self {
        case .verbose: return "💬"
        case .debug:   return "🔍"
        case .info:    return "ℹ️"
        case .warning: return "⚠️"
        case .error:   return "❌"
        }
    }
}

// MARK: - Log Category

/// 日志分类枚举，每个分类对应一个 OSLog 实例
enum LogCategory: String, CaseIterable, Codable, Sendable {
    case connection   = "Connection"
    case audio        = "Audio"
    case ui           = "UI"
    case model        = "Model"
    case handoff      = "Handoff"
    case general      = "General"
    case notification = "Notification"
    case database     = "Database"
    case certificate  = "Certificate"
    case plugin       = "Plugin"
    case network      = "Network"
    case codec        = "Codec"
    case discovery    = "Discovery"

    /// UserDefaults key for this category's log level
    var levelKey: String { "LogLevel_\(rawValue)" }

    /// UserDefaults key for this category's enabled state
    var enabledKey: String { "LogEnabled_\(rawValue)" }
}

// MARK: - Log Manager

/// 中心日志管理器，统管所有日志行为
/// 支持：分类开关、等级过滤、环境变量覆盖、可选文件持久化
final class LogManager: @unchecked Sendable {
    static let shared = LogManager()

    private let subsystem = "cn.hotxiang.Mumble"

    /// OSLog 实例缓存
    private var loggers: [LogCategory: OSLog] = [:]

    /// 每个分类的日志等级
    private var categoryLevels: [LogCategory: LogLevel] = [:]

    /// 每个分类的开关状态
    private var categoryEnabled: [LogCategory: Bool] = [:]

    /// 全局开关
    var isEnabled: Bool {
        get { _isEnabled }
        set {
            _isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: "LogGlobalEnabled")
        }
    }
    private var _isEnabled: Bool = true

    /// 文件持久化开关
    var isFilePersistenceEnabled: Bool {
        get { _isFilePersistenceEnabled }
        set {
            _isFilePersistenceEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: "LogFilePersistenceEnabled")
            if newValue {
                fileWriter.open()
            } else {
                fileWriter.close()
            }
        }
    }
    private var _isFilePersistenceEnabled: Bool = false

    /// 文件写入器（internal 以便 LogSettingsView 访问导出功能）
    let fileWriter = LogFileWriter()

    /// 串行队列保护并发访问
    private let queue = DispatchQueue(label: "cn.hotxiang.Mumble.LogManager", qos: .utility)

    /// 最近日志缓冲，供 WebSocket 调试与 AI agent 回放使用
    private var recentEntries: [RecentLogEntry] = []
    private let maxRecentEntries = 2000

    /// 默认日志等级
    private let defaultLevel: LogLevel = {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()

    private init() {
        // 初始化所有分类的 OSLog 实例
        for category in LogCategory.allCases {
            loggers[category] = OSLog(subsystem: subsystem, category: category.rawValue)
        }

        // 从 UserDefaults 恢复配置
        loadConfiguration()

        // 环境变量覆盖（优先级最高）
        applyEnvironmentOverrides()
    }

    // MARK: - Configuration

    private func loadConfiguration() {
        let defaults = UserDefaults.standard

        _isEnabled = defaults.object(forKey: "LogGlobalEnabled") as? Bool ?? true
        _isFilePersistenceEnabled = defaults.object(forKey: "LogFilePersistenceEnabled") as? Bool ?? false

        for category in LogCategory.allCases {
            if let savedLevel = defaults.object(forKey: category.levelKey) as? Int,
               let level = LogLevel(rawValue: savedLevel) {
                categoryLevels[category] = level
            } else {
                categoryLevels[category] = defaultLevel
            }

            if let savedEnabled = defaults.object(forKey: category.enabledKey) as? Bool {
                categoryEnabled[category] = savedEnabled
            } else {
                categoryEnabled[category] = true
            }
        }

        if _isFilePersistenceEnabled {
            fileWriter.open()
        }
    }

    /// 环境变量覆盖：
    /// - MUMBLE_LOG_LEVEL=verbose|debug|info|warning|error  (全局等级)
    /// - MUMBLE_LOG_DISABLED=audio,plugin  (禁用指定分类)
    /// - MUMBLE_LOG_VERBOSE=connection,network  (指定分类设为 verbose)
    /// - MUMBLE_LOG_FILE=1  (启用文件持久化)
    private func applyEnvironmentOverrides() {
        let env = ProcessInfo.processInfo.environment

        // 全局等级覆盖
        if let levelStr = env["MUMBLE_LOG_LEVEL"]?.lowercased() {
            let level: LogLevel? = switch levelStr {
            case "verbose": .verbose
            case "debug":   .debug
            case "info":    .info
            case "warning": .warning
            case "error":   .error
            default: nil
            }
            if let level {
                for category in LogCategory.allCases {
                    categoryLevels[category] = level
                }
            }
        }

        // 禁用指定分类
        if let disabled = env["MUMBLE_LOG_DISABLED"] {
            let names = disabled.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for name in names {
                if let cat = LogCategory(rawValue: name) ?? LogCategory.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
                    categoryEnabled[cat] = false
                }
            }
        }

        // 指定分类设为 verbose
        if let verbose = env["MUMBLE_LOG_VERBOSE"] {
            let names = verbose.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for name in names {
                if let cat = LogCategory(rawValue: name) ?? LogCategory.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
                    categoryLevels[cat] = .verbose
                    categoryEnabled[cat] = true
                }
            }
        }

        // 文件持久化覆盖
        if let fileFlag = env["MUMBLE_LOG_FILE"], fileFlag == "1" || fileFlag.lowercased() == "true" {
            _isFilePersistenceEnabled = true
            fileWriter.open()
        }
    }

    // MARK: - Level / Enable Control

    func level(for category: LogCategory) -> LogLevel {
        queue.sync { categoryLevels[category] ?? defaultLevel }
    }

    func setLevel(_ level: LogLevel, for category: LogCategory) {
        queue.sync {
            categoryLevels[category] = level
            UserDefaults.standard.set(level.rawValue, forKey: category.levelKey)
        }
    }

    func isEnabled(category: LogCategory) -> Bool {
        queue.sync { categoryEnabled[category] ?? true }
    }

    func setEnabled(_ enabled: Bool, for category: LogCategory) {
        queue.sync {
            categoryEnabled[category] = enabled
            UserDefaults.standard.set(enabled, forKey: category.enabledKey)
        }
    }

    /// 重置所有分类到默认等级和启用状态
    func resetToDefaults() {
        queue.sync {
            for category in LogCategory.allCases {
                categoryLevels[category] = defaultLevel
                categoryEnabled[category] = true
                UserDefaults.standard.removeObject(forKey: category.levelKey)
                UserDefaults.standard.removeObject(forKey: category.enabledKey)
            }
            _isEnabled = true
            _isFilePersistenceEnabled = false
            UserDefaults.standard.removeObject(forKey: "LogGlobalEnabled")
            UserDefaults.standard.removeObject(forKey: "LogFilePersistenceEnabled")
            fileWriter.close()
            recentEntries.removeAll()
        }
    }

    func clearRecentEntries() {
        queue.sync {
            recentEntries.removeAll()
        }
    }

    func getRecentEntries(limit: Int = 200,
                          category: LogCategory? = nil,
                          minimumLevel: LogLevel? = nil) -> [[String: Any]] {
        queue.sync {
            let boundedLimit = max(0, min(limit, maxRecentEntries))
            guard boundedLimit > 0 else { return [] }

            let filtered = recentEntries.filter { entry in
                if let category, entry.category != category.rawValue {
                    return false
                }
                if let minimumLevel,
                   let entryLevel = LogLevel(rawValue: entry.levelRaw),
                   entryLevel < minimumLevel {
                    return false
                }
                return true
            }
            return Array(filtered.suffix(boundedLimit)).map(\.dictionary)
        }
    }

    // MARK: - Core Log Method

    func log(_ level: LogLevel, category: LogCategory, message: @autoclosure () -> String,
             file: String = #file, function: String = #function, line: Int = #line) {
        // 快速路径：全局关闭
        guard _isEnabled else { return }

        // 分类开关检查
        guard categoryEnabled[category] ?? true else { return }

        // 等级过滤
        let threshold = categoryLevels[category] ?? defaultLevel
        guard level >= threshold else { return }

        let msg = message()
        let timestamp = LogManager.timestampFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let entry = RecentLogEntry(
            timestamp: timestamp,
            category: category.rawValue,
            level: level.apiValue,
            levelRaw: level.rawValue,
            symbol: level.symbol,
            message: msg,
            file: fileName,
            function: function,
            line: line
        )

        // OSLog 输出
        if let osLog = loggers[category] {
            os_log("%{public}@", log: osLog, type: level.osLogType, msg)
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.recentEntries.append(entry)
            if self.recentEntries.count > self.maxRecentEntries {
                self.recentEntries.removeFirst(self.recentEntries.count - self.maxRecentEntries)
            }
        }

        NotificationCenter.default.post(name: .mumbleLogEntryAdded, object: nil, userInfo: entry.dictionary)

        // 可选文件持久化
        if _isFilePersistenceEnabled {
            let lineText = "\(timestamp) \(level.symbol) [\(category.rawValue)] \(fileName):\(line) \(function) — \(msg)"
            fileWriter.write(lineText)
        }
    }

    /// C 桥接入口（供 ObjC/MumbleKit 调用）
    func logFromC(levelRaw: Int32, categoryRaw: UnsafePointer<CChar>, message: UnsafePointer<CChar>,
                  file: UnsafePointer<CChar>, function: UnsafePointer<CChar>, line: Int32) {
        let level = LogLevel(rawValue: Int(levelRaw)) ?? .info
        let catName = String(cString: categoryRaw)
        let category = LogCategory.allCases.first(where: { $0.rawValue.lowercased() == catName.lowercased() }) ?? .general
        let msg = String(cString: message)
        let fileStr = String(cString: file)
        let funcStr = String(cString: function)

        log(level, category: category, message: msg, file: fileStr, function: funcStr, line: Int(line))
    }

    // MARK: - Timestamp Formatter

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Log File Writer

/// 日志文件写入器，写入 App 的 Documents/Logs/ 目录
/// 日志文件按天滚动，保留最近 7 天
final class LogFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cn.hotxiang.Mumble.LogFileWriter", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentDate: String = ""
    private let maxDays = 7

    var logDirectory: URL {
        let base: URL
        #if os(iOS)
        base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        #else
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mumble")
        #endif
        return base.appendingPathComponent("Logs")
    }

    func open() {
        queue.async { [weak self] in
            self?.openInternal()
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }
    }

    func write(_ entry: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let today = Self.dateString()
            if today != currentDate {
                openInternal()
                cleanOldFiles()
            }
            if let data = (entry + "\n").data(using: .utf8) {
                fileHandle?.write(data)
            }
        }
    }

    /// 获取当前日志文件路径（供导出用）
    var currentLogFileURL: URL? {
        let today = Self.dateString()
        let url = logDirectory.appendingPathComponent("mumble-\(today).log")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 获取所有日志文件（供导出用）
    var allLogFileURLs: [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }
        return files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func openInternal() {
        fileHandle?.closeFile()

        let fm = FileManager.default
        let dir = logDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let today = Self.dateString()
        currentDate = today
        let filePath = dir.appendingPathComponent("mumble-\(today).log")

        if !fm.fileExists(atPath: filePath.path) {
            fm.createFile(atPath: filePath.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: filePath)
        fileHandle?.seekToEndOfFile()
    }

    private func cleanOldFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else { return }
        let logFiles = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if logFiles.count > maxDays {
            for file in logFiles.prefix(logFiles.count - maxDays) {
                try? fm.removeItem(at: file)
            }
        }
    }

    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

// MARK: - Log Proxy

/// 代理类型，提供类似 Logger 的调用接口
/// 用法：MumbleLogger.audio.info("xxx")
struct LogProxy: Sendable {
    let category: LogCategory

    func verbose(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        LogManager.shared.log(.verbose, category: category, message: message(), file: file, function: function, line: line)
    }

    func debug(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        LogManager.shared.log(.debug, category: category, message: message(), file: file, function: function, line: line)
    }

    func info(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        LogManager.shared.log(.info, category: category, message: message(), file: file, function: function, line: line)
    }

    func warning(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        LogManager.shared.log(.warning, category: category, message: message(), file: file, function: function, line: line)
    }

    func error(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        LogManager.shared.log(.error, category: category, message: message(), file: file, function: function, line: line)
    }
}

// MARK: - MumbleLogger (统一入口)

/// 统一日志入口，所有模块通过此枚举访问日志代理
/// 用法与之前的 Logger 完全兼容：MumbleLogger.connection.info("...")
/// 新增 .warning / .verbose 两个等级
enum MumbleLogger {
    static let connection   = LogProxy(category: .connection)
    static let audio        = LogProxy(category: .audio)
    static let ui           = LogProxy(category: .ui)
    static let model        = LogProxy(category: .model)
    static let handoff      = LogProxy(category: .handoff)
    static let general      = LogProxy(category: .general)
    static let notification = LogProxy(category: .notification)
    static let database     = LogProxy(category: .database)
    static let certificate  = LogProxy(category: .certificate)
    static let plugin       = LogProxy(category: .plugin)
    static let network      = LogProxy(category: .network)
    static let codec        = LogProxy(category: .codec)
    static let discovery    = LogProxy(category: .discovery)
}

// MARK: - C Bridge (供 ObjC / MumbleKit 调用)

/// C 函数桥接 — ObjC 宏最终调用此函数
@_cdecl("MumbleLogBridge")
public func MumbleLogBridge(level: Int32, category: UnsafePointer<CChar>,
                            message: UnsafePointer<CChar>,
                            file: UnsafePointer<CChar>,
                            function: UnsafePointer<CChar>,
                            line: Int32) {
    LogManager.shared.logFromC(levelRaw: level, categoryRaw: category, message: message,
                               file: file, function: function, line: line)
}
