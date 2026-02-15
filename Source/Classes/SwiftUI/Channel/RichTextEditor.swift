//
//  RichTextEditor.swift
//  Mumble
//
//  WYSIWYG HTML editor using WKWebView with source code toggle and image paste support.
//

import SwiftUI
import WebKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Rich Text Editor (Visual + Source)

struct RichTextEditor: View {
    @Binding var htmlText: String
    
    @State private var isSourceMode: Bool = false
    @State private var editorHeight: CGFloat = 200
    
    private var clampedEditorHeight: CGFloat {
        min(max(editorHeight, 200), 500)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 模式切换（居中）
            Picker("Mode", selection: $isSourceMode) {
                Text("Visual").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            
            if isSourceMode {
                // 源码编辑模式
                TextEditor(text: $htmlText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(4)
            } else {
                // 可视化编辑模式
                WYSIWYGEditorView(htmlText: $htmlText, editorHeight: $editorHeight)
                    .frame(height: clampedEditorHeight)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - WYSIWYG Editor (WKWebView wrapper)

struct WYSIWYGEditorView: PlatformViewRepresentable {
    @Binding var htmlText: String
    @Binding var editorHeight: CGFloat
    
    #if os(macOS)
    typealias NSViewType = WKWebView
    
    func makeNSView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        // 每次 SwiftUI 驱动的更新都把最新值传入 coordinator
        context.coordinator.externalHTMLUpdate(htmlText)
    }
    #else
    typealias UIViewType = WKWebView
    
    func makeUIView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.externalHTMLUpdate(htmlText)
    }
    #endif
    
    func makeCoordinator() -> Coordinator {
        Coordinator(htmlBinding: $htmlText, heightBinding: $editorHeight)
    }
    
    private func createWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "htmlChanged")
        userController.add(context.coordinator, name: "heightChanged")
        userController.add(context.coordinator, name: "editorReady")
        userController.add(context.coordinator, name: "imagePasted")
        config.userContentController = userController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        
        context.coordinator.webView = webView
        loadEditorShell(in: webView)
        return webView
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        private var htmlBinding: Binding<String>
        private var heightBinding: Binding<CGFloat>
        var webView: WKWebView?
        
        /// 编辑器是否已就绪（JS 脚本已加载完成）
        private var isReady = false
        /// 最新的从 SwiftUI 外部传入的 HTML（通过 updateView）
        private var latestExternalHTML: String = ""
        /// 上次从 JS 端接收到的 HTML（用户编辑产生的）
        private var lastHTMLFromJS: String = ""
        /// 是否正在向 JS 推送内容（防止回环）
        private var isPushing = false
        /// 防抖任务：将 HTML 中嵌入图片统一压缩
        private var embeddedImageNormalizeTask: Task<Void, Never>?
        
        init(htmlBinding: Binding<String>, heightBinding: Binding<CGFloat>) {
            self.htmlBinding = htmlBinding
            self.heightBinding = heightBinding
        }
        
        /// 从 SwiftUI 的 updateView 调用 — 传入最新的绑定值
        func externalHTMLUpdate(_ html: String) {
            latestExternalHTML = html
            pushToJSIfNeeded()
        }
        
        /// 当编辑器就绪或外部内容变化时，尝试推送到 JS
        private func pushToJSIfNeeded() {
            guard isReady, !isPushing else { return }
            // 只在外部值与 JS 端最新值不同时才推送（避免用户编辑被覆盖）
            if latestExternalHTML != lastHTMLFromJS {
                pushToJS(latestExternalHTML)
            }
        }
        
        private func pushToJS(_ html: String) {
            guard let webView = webView else { return }
            isPushing = true
            lastHTMLFromJS = html  // 预设，防止回环
            let escaped = html
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            webView.evaluateJavaScript("setContent('\(escaped)')") { [weak self] _, _ in
                self?.isPushing = false
            }
        }
        
        // MARK: - WKScriptMessageHandler
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "editorReady":
                isReady = true
                // 编辑器就绪 — 推送 SwiftUI 侧最新的内容
                pushToJSIfNeeded()
                
            case "htmlChanged":
                guard !isPushing, let html = message.body as? String else { return }
                lastHTMLFromJS = html
                latestExternalHTML = html  // 同步，防止 updateView 触发无谓推送
                DispatchQueue.main.async {
                    self.htmlBinding.wrappedValue = html
                }
                // 双保险：无论图片通过哪种粘贴路径进入编辑器，只要出现 data:image 就尝试二次压缩
                if html.contains("data:image/") {
                    scheduleEmbeddedImageNormalization(for: html)
                }
                
            case "heightChanged":
                let rawHeight: CGFloat?
                if let h = message.body as? CGFloat {
                    rawHeight = h
                } else if let h = message.body as? Double {
                    rawHeight = CGFloat(h)
                } else if let h = message.body as? NSNumber {
                    rawHeight = CGFloat(truncating: h)
                } else {
                    rawHeight = nil
                }
                if let h = rawHeight, h.isFinite, h > 0 {
                    DispatchQueue.main.async {
                        // 限制可视高度，避免异常值导致 AutoLayout 报错
                        self.heightBinding.wrappedValue = min(max(h, 200), 5000)
                    }
                }
                
            case "imagePasted":
                guard let rawDataURL = message.body as? String else { return }
                Task { [weak self] in
                    guard let self = self else { return }
                    // 与消息发送一致：先按“分辨率优先，再降 JPEG 质量”的策略压缩，减少 HTML 字符体积。
                    guard let compressed = self.compressedImageDataURL(from: rawDataURL, maxBytes: 120 * 1024) else {
                        return // 压缩失败时不回退插入原图，避免超长 HTML
                    }
                    self.insertImageDataURLIntoEditor(compressed)
                }
                
            default:
                break
            }
        }
        
        // MARK: - WKNavigationDelegate
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
        
        #if os(macOS)
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.allowedContentTypes = [.image]
            panel.begin { response in
                if response == .OK {
                    completionHandler(panel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        }
        #endif
        
        private func insertImageDataURLIntoEditor(_ dataURL: String) {
            guard let webView = webView else { return }
            let escaped = dataURL
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            webView.evaluateJavaScript("insertImageDataURL('\(escaped)')", completionHandler: nil)
        }

        private func scheduleEmbeddedImageNormalization(for html: String) {
            embeddedImageNormalizeTask?.cancel()
            embeddedImageNormalizeTask = Task { [weak self] in
                guard let self = self else { return }
                // 防抖，避免用户正在连续输入时频繁重压缩
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                
                let normalized = await Task.detached(priority: .userInitiated) {
                    Self.compressEmbeddedImagesInHTML(html, maxBytesPerImage: 250 * 1024)
                }.value
                
                guard !Task.isCancelled else { return }
                // 仅当内容未继续变化时回写，避免覆盖用户后续输入
                guard self.lastHTMLFromJS == html || self.latestExternalHTML == html else { return }
                guard normalized != html else { return }
                
                self.latestExternalHTML = normalized
                self.lastHTMLFromJS = normalized
                self.htmlBinding.wrappedValue = normalized
                self.pushToJS(normalized)
            }
        }
    }
}
