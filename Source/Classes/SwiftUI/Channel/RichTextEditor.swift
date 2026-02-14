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
        loadEditorShell(in: webView)
        return webView
    }
    
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
                display: flex; flex-wrap: wrap; gap: 2px;
                padding: 4px 6px;
                background: \(toolbarBg);
                border-bottom: 1px solid \(borderColor);
                position: sticky; top: 0; z-index: 100;
            }
            .toolbar button {
                background: none; border: 1px solid transparent; border-radius: 4px;
                padding: 4px 8px; cursor: pointer; font-size: 13px;
                color: \(textColor); min-width: 28px; text-align: center;
            }
            .toolbar button:hover {
                background: \(isDark ? "#3a3a3a" : "#e0e0e0");
                border-color: \(borderColor);
            }
            .toolbar .sep { width: 1px; background: \(borderColor); margin: 2px 4px; }
            .toolbar .dropdown {
                position: relative; display: inline-block;
            }
            .toolbar .dropdown-btn {
                background: none; border: 1px solid transparent; border-radius: 4px;
                padding: 4px 8px; cursor: pointer; font-size: 13px;
                color: \(textColor); text-align: center;
            }
            .toolbar .dropdown-btn:hover {
                background: \(isDark ? "#3a3a3a" : "#e0e0e0");
                border-color: \(borderColor);
            }
            .toolbar .dropdown-panel {
                display: none; position: absolute; top: 100%; left: 0;
                background: \(isDark ? "#2d2d2d" : "#fff");
                border: 1px solid \(borderColor);
                border-radius: 6px; padding: 8px;
                box-shadow: 0 4px 12px rgba(0,0,0,0.3);
                z-index: 200; min-width: 160px;
            }
            .toolbar .dropdown-panel.show { display: block; }
            .color-grid {
                display: grid; grid-template-columns: repeat(6, 1fr); gap: 4px;
                margin-bottom: 6px;
            }
            .color-swatch {
                width: 24px; height: 24px; border-radius: 4px; cursor: pointer;
                border: 2px solid transparent;
            }
            .color-swatch:hover { border-color: \(textColor); }
            .color-input-row { display: flex; align-items: center; gap: 4px; margin-top: 4px; }
            .color-input-row input[type=color] {
                width: 28px; height: 28px; border: none; padding: 0;
                cursor: pointer; border-radius: 4px; background: none;
            }
            .color-input-row span { font-size: 11px; color: \(isDark ? "#999" : "#666"); }
            .size-list button, .font-list button {
                display: block; width: 100%; text-align: left;
                background: none; border: none; padding: 5px 10px;
                color: \(textColor); cursor: pointer; font-size: 13px;
                border-radius: 4px;
            }
            .size-list button:hover, .font-list button:hover {
                background: \(isDark ? "#3a3a3a" : "#e8e8e8");
            }
            #editor {
                padding: 10px; min-height: 120px; outline: none;
                line-height: 1.5; word-wrap: break-word; overflow-wrap: break-word;
            }
            #editor:empty:before {
                content: 'Enter description...';
                color: \(isDark ? "#666" : "#999");
                pointer-events: none;
            }
            #editor img { max-width: 100%; height: auto; border-radius: 4px; margin: 4px 0; }
            #editor a { color: #4a9eff; }
            #editor h1, #editor h2, #editor h3 { margin: 8px 0 4px 0; }
            #editor ul, #editor ol { padding-left: 20px; margin: 4px 0; }
        </style>
        </head>
        <body>
        <div class="toolbar">
            <button onmousedown="event.preventDefault()" onclick="fmt('bold')" title="Bold"><b>B</b></button>
            <button onmousedown="event.preventDefault()" onclick="fmt('italic')" title="Italic"><i>I</i></button>
            <button onmousedown="event.preventDefault()" onclick="fmt('underline')" title="Underline"><u>U</u></button>
            <button onmousedown="event.preventDefault()" onclick="fmt('strikeThrough')" title="Strikethrough"><s>S</s></button>
            <div class="sep"></div>

            <!-- 颜色选择器 -->
            <div class="dropdown" id="colorDropdown">
                <button class="dropdown-btn" onmousedown="event.preventDefault()" onclick="togglePanel('colorPanel')" title="Text Color">
                    <span style="border-bottom:3px solid currentColor; padding-bottom:1px">A</span> ▾
                </button>
                <div class="dropdown-panel" id="colorPanel" onmousedown="event.preventDefault()">
                    <div class="color-grid">
                        <div class="color-swatch" style="background:#000" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#000')"></div>
                        <div class="color-swatch" style="background:#e03c31" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#e03c31')"></div>
                        <div class="color-swatch" style="background:#ff8c00" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#ff8c00')"></div>
                        <div class="color-swatch" style="background:#ffd700" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#ffd700')"></div>
                        <div class="color-swatch" style="background:#2ecc40" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#2ecc40')"></div>
                        <div class="color-swatch" style="background:#0074d9" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#0074d9')"></div>
                        <div class="color-swatch" style="background:#b10dc9" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#b10dc9')"></div>
                        <div class="color-swatch" style="background:#ff69b4" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#ff69b4')"></div>
                        <div class="color-swatch" style="background:#aaa" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#aaa')"></div>
                        <div class="color-swatch" style="background:#fff; border:1px solid #ccc" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#fff')"></div>
                        <div class="color-swatch" style="background:#795548" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#795548')"></div>
                        <div class="color-swatch" style="background:#01ff70" onmousedown="event.preventDefault();event.stopPropagation()" onclick="pickColor('#01ff70')"></div>
                    </div>
                    <div class="color-input-row">
                        <input type="color" id="customColor" value="#ff0000" onchange="pickColor(this.value)"/>
                        <span>Custom</span>
                    </div>
                </div>
            </div>

            <!-- 文字大小 -->
            <div class="dropdown" id="sizeDropdown">
                <button class="dropdown-btn" onmousedown="event.preventDefault()" onclick="togglePanel('sizePanel')" title="Text Size">
                    T<small>T</small> ▾
                </button>
                <div class="dropdown-panel" id="sizePanel" onmousedown="event.preventDefault()">
                    <div class="size-list">
                        <button onmousedown="event.preventDefault()" onclick="setSize(1)">Tiny</button>
                        <button onmousedown="event.preventDefault()" onclick="setSize(2)">Small</button>
                        <button onmousedown="event.preventDefault()" onclick="setSize(3)">Normal</button>
                        <button onmousedown="event.preventDefault()" onclick="setSize(4)">Large</button>
                        <button onmousedown="event.preventDefault()" onclick="setSize(5)">Huge</button>
                        <button onmousedown="event.preventDefault()" onclick="setSize(7)">Massive</button>
                        <hr style="margin:4px 0; border:none; border-top:1px solid \(borderColor)">
                        <button onmousedown="event.preventDefault()" onclick="setBlock('h1')"><b style="font-size:20px">Heading 1</b></button>
                        <button onmousedown="event.preventDefault()" onclick="setBlock('h2')"><b style="font-size:17px">Heading 2</b></button>
                        <button onmousedown="event.preventDefault()" onclick="setBlock('h3')"><b style="font-size:15px">Heading 3</b></button>
                        <button onmousedown="event.preventDefault()" onclick="setBlock('p')">Paragraph</button>
                    </div>
                </div>
            </div>

            <!-- 字体选择 -->
            <div class="dropdown" id="fontDropdown">
                <button class="dropdown-btn" onmousedown="event.preventDefault()" onclick="togglePanel('fontPanel')" title="Font">
                    F ▾
                </button>
                <div class="dropdown-panel" id="fontPanel" style="min-width:180px" onmousedown="event.preventDefault()">
                    <div class="font-list">
                        <button onmousedown="event.preventDefault()" onclick="setFont('sans-serif')" style="font-family:sans-serif">Sans Serif</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('serif')" style="font-family:serif">Serif</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('monospace')" style="font-family:monospace">Monospace</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('Arial')" style="font-family:Arial">Arial</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('Georgia')" style="font-family:Georgia">Georgia</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('Courier New')" style="font-family:'Courier New'">Courier New</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('Helvetica')" style="font-family:Helvetica">Helvetica</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('Times New Roman')" style="font-family:'Times New Roman'">Times New Roman</button>
                        <button onmousedown="event.preventDefault()" onclick="setFont('Verdana')" style="font-family:Verdana">Verdana</button>
                    </div>
                </div>
            </div>

            <div class="sep"></div>
            <button onmousedown="event.preventDefault()" onclick="fmt('insertUnorderedList')" title="Bullet List">&#8226;</button>
            <button onmousedown="event.preventDefault()" onclick="fmt('insertOrderedList')" title="Numbered List">1.</button>
            <button onmousedown="event.preventDefault()" onclick="insertLink()" title="Insert Link">&#128279;</button>
        </div>
        <div id="editor" contenteditable="true"></div>
        <script>
            var editor = document.getElementById('editor');
            var _suppress = false;
            
            function fmt(cmd, val) {
                document.execCommand(cmd, false, val || null);
                editor.focus();
                notifyChange();
            }
            // --- 弹出面板管理 ---
            function togglePanel(id) {
                var panel = document.getElementById(id);
                var wasOpen = panel.classList.contains('show');
                closeAllPanels();
                if (!wasOpen) panel.classList.add('show');
            }
            function closeAllPanels() {
                var panels = document.querySelectorAll('.dropdown-panel');
                for (var i = 0; i < panels.length; i++) panels[i].classList.remove('show');
            }
            document.addEventListener('click', function(e) {
                if (!e.target.closest('.dropdown')) closeAllPanels();
            });

            // --- 颜色 ---
            function pickColor(c) {
                // 先恢复焦点和执行命令（选区保持），再关闭面板
                editor.focus();
                document.execCommand('foreColor', false, c);
                closeAllPanels();
                notifyChange();
            }

            // --- 字号（1-7 使用 fontSize 命令）---
            function setSize(s) {
                editor.focus();
                document.execCommand('fontSize', false, s);
                closeAllPanels();
                notifyChange();
            }

            // --- 块级标签 ---
            function setBlock(tag) {
                editor.focus();
                document.execCommand('formatBlock', false, '<' + tag + '>');
                closeAllPanels();
                notifyChange();
            }

            // --- 字体 ---
            function setFont(f) {
                editor.focus();
                document.execCommand('fontName', false, f);
                closeAllPanels();
                notifyChange();
            }

            function insertLink() {
                var url = prompt('Enter URL:', 'https://');
                if (url) { document.execCommand('createLink', false, url); notifyChange(); }
            }
            function notifyChange() {
                if (_suppress) return;
                var html = editor.innerHTML;
                window.webkit.messageHandlers.htmlChanged.postMessage(html);
                reportHeight();
            }
            function reportHeight() {
                window.webkit.messageHandlers.heightChanged.postMessage(
                    document.documentElement.scrollHeight
                );
            }
            function setContent(html) {
                _suppress = true;
                editor.innerHTML = html;
                _suppress = false;
                reportHeight();
            }
            editor.addEventListener('input', notifyChange);
            editor.addEventListener('paste', function(e) {
                var items = (e.clipboardData || e.originalEvent.clipboardData).items;
                for (var i = 0; i < items.length; i++) {
                    if (items[i].type.indexOf('image') !== -1) {
                        e.preventDefault();
                        var blob = items[i].getAsFile();
                        var reader = new FileReader();
                        reader.onload = function(ev) {
                            document.execCommand('insertHTML', false,
                                '<img src="' + ev.target.result + '" style="max-width:100%"/>');
                            notifyChange();
                        };
                        reader.readAsDataURL(blob);
                        return;
                    }
                }
                setTimeout(notifyChange, 50);
            });
            window.webkit.messageHandlers.editorReady.postMessage('ready');
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
                
            case "heightChanged":
                if let h = message.body as? CGFloat {
                    DispatchQueue.main.async {
                        self.heightBinding.wrappedValue = max(h, 200)
                    }
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
    }
}
