//
//  RichTextEditor.swift
//  Mumble
//
//  WYSIWYG HTML editor using WKWebView with source code toggle and image paste support.
//

import SwiftUI
import WebKit

// MARK: - Rich Text Editor (Visual + Source)

struct RichTextEditor: View {
    @Binding var htmlText: String
    
    @State private var isSourceMode: Bool = false
    @State private var editorHeight: CGFloat = 200
    
    var body: some View {
        VStack(spacing: 0) {
            // 模式切换
            HStack {
                Picker("", selection: $isSourceMode) {
                    Text("Visual").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                
                Spacer()
            }
            .padding(.horizontal, 8)
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
                    .frame(minHeight: max(editorHeight, 200), maxHeight: 500)
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
        context.coordinator.updateContentIfNeeded(htmlText)
    }
    #else
    typealias UIViewType = WKWebView
    
    func makeUIView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateContentIfNeeded(htmlText)
    }
    #endif
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func createWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "htmlChanged")
        userController.add(context.coordinator, name: "heightChanged")
        userController.add(context.coordinator, name: "editorReady")
        config.userContentController = userController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        
        context.coordinator.webView = webView
        // 记录初始内容，在 editorReady 回调中设置
        context.coordinator.pendingInitialHTML = htmlText
        loadEditorShell(in: webView)
        return webView
    }
    
    /// 只加载编辑器骨架（不含内容），内容通过 JS 设置
    private func loadEditorShell(in webView: WKWebView) {
        let isDark: Bool
        #if os(macOS)
        isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        isDark = UITraitCollection.current.userInterfaceStyle == .dark
        #endif
        
        let bgColor = isDark ? "#1e1e1e" : "#ffffff"
        let textColor = isDark ? "#d4d4d4" : "#1e1e1e"
        let borderColor = isDark ? "#444" : "#ccc"
        let toolbarBg = isDark ? "#2d2d2d" : "#f0f0f0"
        
        let fullHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
        <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 14px;
                color: \(textColor);
                background: \(bgColor);
                padding: 0;
            }
            .toolbar {
                display: flex;
                flex-wrap: wrap;
                gap: 2px;
                padding: 4px 6px;
                background: \(toolbarBg);
                border-bottom: 1px solid \(borderColor);
                position: sticky;
                top: 0;
                z-index: 100;
            }
            .toolbar button {
                background: none;
                border: 1px solid transparent;
                border-radius: 4px;
                padding: 4px 8px;
                cursor: pointer;
                font-size: 13px;
                color: \(textColor);
                min-width: 28px;
                text-align: center;
            }
            .toolbar button:hover {
                background: \(isDark ? "#3a3a3a" : "#e0e0e0");
                border-color: \(borderColor);
            }
            .toolbar .sep {
                width: 1px;
                background: \(borderColor);
                margin: 2px 4px;
            }
            #editor {
                padding: 10px;
                min-height: 120px;
                outline: none;
                line-height: 1.5;
                word-wrap: break-word;
                overflow-wrap: break-word;
            }
            #editor:empty:before {
                content: 'Enter description...';
                color: \(isDark ? "#666" : "#999");
                pointer-events: none;
            }
            #editor img {
                max-width: 100%;
                height: auto;
                border-radius: 4px;
                margin: 4px 0;
            }
            #editor a { color: #4a9eff; }
            #editor h1, #editor h2, #editor h3 { margin: 8px 0 4px 0; }
            #editor ul, #editor ol { padding-left: 20px; margin: 4px 0; }
        </style>
        </head>
        <body>
        <div class="toolbar">
            <button onmousedown="event.preventDefault()" onclick="fmt('bold')"><b>B</b></button>
            <button onmousedown="event.preventDefault()" onclick="fmt('italic')"><i>I</i></button>
            <button onmousedown="event.preventDefault()" onclick="fmt('underline')"><u>U</u></button>
            <button onmousedown="event.preventDefault()" onclick="fmt('strikeThrough')"><s>S</s></button>
            <div class="sep"></div>
            <button onmousedown="event.preventDefault()" onclick="setColor('red')" style="color:red">A</button>
            <button onmousedown="event.preventDefault()" onclick="setColor('blue')" style="color:blue">A</button>
            <button onmousedown="event.preventDefault()" onclick="setColor('green')" style="color:green">A</button>
            <button onmousedown="event.preventDefault()" onclick="setColor('orange')" style="color:orange">A</button>
            <div class="sep"></div>
            <button onmousedown="event.preventDefault()" onclick="fmt('formatBlock','<h1>')">H1</button>
            <button onmousedown="event.preventDefault()" onclick="fmt('formatBlock','<h2>')">H2</button>
            <button onmousedown="event.preventDefault()" onclick="fmt('formatBlock','<h3>')">H3</button>
            <button onmousedown="event.preventDefault()" onclick="fmt('formatBlock','<p>')">P</button>
            <div class="sep"></div>
            <button onmousedown="event.preventDefault()" onclick="fmt('insertUnorderedList')">&#8226;</button>
            <button onmousedown="event.preventDefault()" onclick="fmt('insertOrderedList')">1.</button>
            <button onmousedown="event.preventDefault()" onclick="insertLink()">&#128279;</button>
        </div>
        <div id="editor" contenteditable="true"></div>
        <script>
            var editor = document.getElementById('editor');
            var _ignoreNextInput = false;
            
            function fmt(cmd, val) {
                document.execCommand(cmd, false, val || null);
                editor.focus();
                notifyChange();
            }
            
            function setColor(c) {
                document.execCommand('foreColor', false, c);
                editor.focus();
                notifyChange();
            }
            
            function insertLink() {
                var url = prompt('Enter URL:', 'https://');
                if (url) {
                    document.execCommand('createLink', false, url);
                    notifyChange();
                }
            }
            
            function notifyChange() {
                if (_ignoreNextInput) return;
                var html = editor.innerHTML;
                // 清除 WKWebView 自动添加的尾部空行
                html = html.replace(/<br\\s*\\/?>\\s*$/i, '');
                html = html.replace(/<div><br\\s*\\/?><\\/div>\\s*$/i, '');
                window.webkit.messageHandlers.htmlChanged.postMessage(html);
                reportHeight();
            }
            
            function reportHeight() {
                var h = document.documentElement.scrollHeight;
                window.webkit.messageHandlers.heightChanged.postMessage(h);
            }
            
            // 从 Swift 端设置内容（不触发 notifyChange）
            function setContent(html) {
                _ignoreNextInput = true;
                editor.innerHTML = html;
                _ignoreNextInput = false;
                reportHeight();
            }
            
            // 获取当前内容
            function getContent() {
                return editor.innerHTML;
            }
            
            editor.addEventListener('input', function() {
                notifyChange();
            });
            
            // 粘贴处理：支持粘贴图片
            editor.addEventListener('paste', function(e) {
                var items = (e.clipboardData || e.originalEvent.clipboardData).items;
                for (var i = 0; i < items.length; i++) {
                    if (items[i].type.indexOf('image') !== -1) {
                        e.preventDefault();
                        var blob = items[i].getAsFile();
                        var reader = new FileReader();
                        reader.onload = function(event) {
                            document.execCommand('insertHTML', false,
                                '<img src="' + event.target.result + '" style="max-width:100%"/>');
                            notifyChange();
                        };
                        reader.readAsDataURL(blob);
                        return;
                    }
                }
                setTimeout(notifyChange, 50);
            });
            
            // 通知 Swift 编辑器已就绪
            window.webkit.messageHandlers.editorReady.postMessage('ready');
        </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WYSIWYGEditorView
        var webView: WKWebView?
        var isReady: Bool = false
        var pendingInitialHTML: String = ""
        /// 上次从 JS 端收到的 HTML，用于避免循环更新
        private var lastReceivedHTML: String = ""
        /// 是否正在从 Swift 端推送内容到 JS
        private var isPushingToJS: Bool = false
        
        init(_ parent: WYSIWYGEditorView) {
            self.parent = parent
        }
        
        /// 当 SwiftUI 绑定改变时（如切换 Source → Visual），仅在内容确实不同时更新 WKWebView
        func updateContentIfNeeded(_ newHTML: String) {
            guard isReady, !isPushingToJS else { return }
            // 只有当外部改变（如源码模式编辑后切回）导致内容不同时才更新
            if newHTML != lastReceivedHTML {
                pushContentToJS(newHTML)
            }
        }
        
        private func pushContentToJS(_ html: String) {
            guard let webView = webView, isReady else { return }
            isPushingToJS = true
            lastReceivedHTML = html
            let escaped = html
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            webView.evaluateJavaScript("setContent('\(escaped)')") { [weak self] _, _ in
                self?.isPushingToJS = false
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "editorReady" {
                isReady = true
                // 编辑器就绪，设置初始内容
                if !pendingInitialHTML.isEmpty {
                    pushContentToJS(pendingInitialHTML)
                    pendingInitialHTML = ""
                } else {
                    // 绑定值可能在 editorReady 之前就被设置了
                    pushContentToJS(parent.htmlText)
                }
            } else if message.name == "htmlChanged", let html = message.body as? String {
                guard !isPushingToJS else { return }
                lastReceivedHTML = html
                DispatchQueue.main.async {
                    self.parent.htmlText = html
                }
            } else if message.name == "heightChanged", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    self.parent.editorHeight = max(height, 200)
                }
            }
        }
        
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
    }
}
