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
            <button onmousedown="event.preventDefault()" onclick="triggerImagePick()" title="Insert Image">&#128247;</button>
        </div>
        <input id="imageInput" type="file" accept="image/*" style="display:none" />
        <div id="editor" contenteditable="true"></div>
        <script>
            var editor = document.getElementById('editor');
            var imageInput = document.getElementById('imageInput');
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
            function triggerImagePick() {
                if (!imageInput) return;
                imageInput.value = '';
                imageInput.click();
            }
            function handlePickedImageFile(file) {
                if (!file || !file.type || file.type.indexOf('image') !== 0) return;
                var reader = new FileReader();
                reader.onload = function(ev) {
                    window.webkit.messageHandlers.imagePasted.postMessage(ev.target.result);
                };
                reader.readAsDataURL(file);
            }
            function postImageDataURL(dataURL) {
                if (!dataURL || dataURL.indexOf('data:image/') !== 0) return false;
                window.webkit.messageHandlers.imagePasted.postMessage(dataURL);
                return true;
            }
            function extractAndRemoveImagesFromHTML(rawHTML) {
                var parser = new DOMParser();
                var doc = parser.parseFromString(rawHTML || '', 'text/html');
                var imageDataURLs = [];
                var imgs = doc.querySelectorAll('img');
                for (var i = 0; i < imgs.length; i++) {
                    var src = imgs[i].getAttribute('src') || '';
                    if (src.indexOf('data:image/') === 0) {
                        imageDataURLs.push(src);
                    }
                    imgs[i].remove();
                }
                return {
                    html: (doc.body && doc.body.innerHTML) ? doc.body.innerHTML : '',
                    images: imageDataURLs
                };
            }
            function insertImageDataURL(dataURL) {
                if (!dataURL) return;
                editor.focus();
                document.execCommand('insertHTML', false,
                    '<img data-managed="1" src="' + dataURL + '" style="max-width:100%"/>');
                notifyChange();
            }
            function sanitizeInlineImages() {
                var imgs = editor.querySelectorAll('img');
                var forwarded = false;
                for (var i = 0; i < imgs.length; i++) {
                    var img = imgs[i];
                    if (!img) continue;
                    if (img.getAttribute('data-managed') === '1') continue;
                    var src = img.getAttribute('src') || '';
                    if (src.indexOf('data:image/') === 0) {
                        postImageDataURL(src);
                        img.remove();
                        forwarded = true;
                    }
                }
                return forwarded;
            }
            function notifyChange() {
                if (_suppress) return;
                // 任何未托管图片都先拦截并交给 native 压缩链，禁止原图直接进入绑定值
                if (sanitizeInlineImages()) {
                    reportHeight();
                    return;
                }
                var html = editor.innerHTML;
                window.webkit.messageHandlers.htmlChanged.postMessage(html);
                reportHeight();
            }
            function reportHeight() {
                var h = Number(document.documentElement.scrollHeight || editor.scrollHeight || 0);
                if (!isFinite(h) || h <= 0) h = 200;
                window.webkit.messageHandlers.heightChanged.postMessage(h);
            }
            function setContent(html) {
                _suppress = true;
                editor.innerHTML = html;
                _suppress = false;
                reportHeight();
            }
            editor.addEventListener('input', notifyChange);
            if (imageInput) {
                imageInput.addEventListener('change', function(e) {
                    var files = e.target && e.target.files;
                    if (files && files.length > 0) {
                        handlePickedImageFile(files[0]);
                    }
                });
            }
            editor.addEventListener('beforeinput', function(e) {
                var t = e.inputType || '';
                if (t === 'insertFromPaste' || t === 'insertFromDrop') {
                    // 双重保险：阻止 WebKit 自己把图片节点直接塞进 contenteditable
                    e.preventDefault();
                }
            });
            editor.addEventListener('paste', function(e) {
                // 强拦截默认粘贴，防止原图直接进入编辑器导致 HTML 过大
                e.preventDefault();
                var clipboard = e.clipboardData || (e.originalEvent && e.originalEvent.clipboardData);
                if (!clipboard) return;
                
                var items = clipboard.items || [];
                var handledImage = false;
                for (var i = 0; i < items.length; i++) {
                    if (items[i].type && items[i].type.indexOf('image') !== -1) {
                        var blob = items[i].getAsFile();
                        if (blob) {
                            handlePickedImageFile(blob);
                            handledImage = true;
                        }
                    }
                }
                if (handledImage) {
                    setTimeout(notifyChange, 50);
                    return;
                }
                
                var html = clipboard.getData('text/html') || '';
                if (html) {
                    var extracted = extractAndRemoveImagesFromHTML(html);
                    if (extracted.html && extracted.html.trim().length > 0) {
                        document.execCommand('insertHTML', false, extracted.html);
                    }
                    for (var j = 0; j < extracted.images.length; j++) {
                        postImageDataURL(extracted.images[j]);
                    }
                    notifyChange();
                    return;
                }
                
                var text = clipboard.getData('text/plain') || '';
                if (text) {
                    document.execCommand('insertText', false, text);
                }
                notifyChange();
            });
            editor.addEventListener('dragover', function(e) {
                e.preventDefault();
            });
            editor.addEventListener('drop', function(e) {
                // 强拦截默认拖拽，避免原图直插
                e.preventDefault();
                var dt = e.dataTransfer;
                if (!dt) return;
                
                var files = dt.files || [];
                var handledImage = false;
                for (var i = 0; i < files.length; i++) {
                    if (files[i].type && files[i].type.indexOf('image') !== -1) {
                        handlePickedImageFile(files[i]);
                        handledImage = true;
                    }
                }
                if (handledImage) {
                    setTimeout(notifyChange, 50);
                    return;
                }
                
                var html = dt.getData('text/html') || '';
                if (html) {
                    var extracted = extractAndRemoveImagesFromHTML(html);
                    if (extracted.html && extracted.html.trim().length > 0) {
                        document.execCommand('insertHTML', false, extracted.html);
                    }
                    for (var j = 0; j < extracted.images.length; j++) {
                        postImageDataURL(extracted.images[j]);
                    }
                    notifyChange();
                    return;
                }
                
                var text = dt.getData('text/plain') || '';
                if (text) {
                    document.execCommand('insertText', false, text);
                }
                notifyChange();
            });
            // 最终兜底：无论图片通过何种内部路径插入，发现未托管图片就移除并交给压缩流程
            var observer = new MutationObserver(function(mutations) {
                var shouldNotify = false;
                for (var m = 0; m < mutations.length; m++) {
                    var nodes = mutations[m].addedNodes || [];
                    for (var n = 0; n < nodes.length; n++) {
                        var node = nodes[n];
                        if (!node || node.nodeType !== 1) continue;
                        var candidates = [];
                        if (node.tagName === 'IMG') {
                            candidates.push(node);
                        } else if (node.querySelectorAll) {
                            var inner = node.querySelectorAll('img');
                            for (var k = 0; k < inner.length; k++) candidates.push(inner[k]);
                        }
                        for (var i = 0; i < candidates.length; i++) {
                            var img = candidates[i];
                            if (!img) continue;
                            var managed = img.getAttribute('data-managed') === '1';
                            if (managed) continue;
                            var src = img.getAttribute('src') || '';
                            if (src.indexOf('data:image/') === 0) {
                                postImageDataURL(src);
                                img.remove();
                                shouldNotify = true;
                            }
                        }
                    }
                }
                if (shouldNotify) notifyChange();
            });
            observer.observe(editor, { childList: true, subtree: true });
            window.webkit.messageHandlers.editorReady.postMessage('ready');
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(fullHTML, baseURL: nil)
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
        
        private func compressedImageDataURL(from rawDataURL: String, maxBytes: Int) -> String? {
            guard let sourceData = Self.dataFromDataURLString(rawDataURL),
                  let image = PlatformImage(data: sourceData),
                  let jpegData = Self.smartCompress(image: image, to: maxBytes) else {
                return nil
            }
            return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        }
        
        nonisolated private static func compressEmbeddedImagesInHTML(_ html: String, maxBytesPerImage: Int) -> String {
            let pattern = "data:image\\/[a-zA-Z0-9.+-]+;base64,[^\"'<>\\s]+"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return html
            }
            
            let ns = html as NSString
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { return html }
            
            var result = html
            var didReplace = false
            
            for match in matches.reversed() {
                let currentNSString = result as NSString
                guard match.range.location != NSNotFound,
                      match.range.location + match.range.length <= currentNSString.length else { continue }
                
                let dataURL = currentNSString.substring(with: match.range)
                guard let sourceData = Self.dataFromDataURLString(dataURL),
                      let image = PlatformImage(data: sourceData),
                      let compressed = Self.smartCompress(image: image, to: maxBytesPerImage) else {
                    continue
                }
                // 只有确实变小才替换，减少无意义重写
                guard compressed.count < sourceData.count else { continue }
                
                let replacement = "data:image/jpeg;base64,\(compressed.base64EncodedString())"
                result = currentNSString.replacingCharacters(in: match.range, with: replacement)
                didReplace = true
            }
            
            return didReplace ? result : html
        }
        
        nonisolated private static func dataFromDataURLString(_ dataURLString: String) -> Data? {
            guard dataURLString.hasPrefix("data:"),
                  let commaRange = dataURLString.range(of: ",") else {
                return nil
            }
            var base64String = String(dataURLString[commaRange.upperBound...])
            base64String = base64String.components(separatedBy: .whitespacesAndNewlines).joined()
            base64String = base64String.removingPercentEncoding ?? base64String
            return Data(base64Encoded: base64String, options: .ignoreUnknownCharacters)
        }
        
        // 与发送图片同策略：先降分辨率，避免过早把 JPEG 质量压得太低。
        nonisolated private static func smartCompress(image: PlatformImage, to maxBytes: Int) -> Data? {
            if let data = image.jpegData(compressionQuality: 1.0), data.count <= maxBytes {
                return data
            }
            
            #if os(iOS)
            let pixelWidth = image.size.width * image.scale
            let pixelHeight = image.size.height * image.scale
            #else
            let pixelWidth = image.size.width
            let pixelHeight = image.size.height
            #endif
            let maxDim = max(pixelWidth, pixelHeight)
            
            var resolutionTiers: [CGFloat] = []
            if maxDim > 2048 {
                resolutionTiers.append(2048)
            } else {
                resolutionTiers.append(maxDim)
            }
            if maxDim > 1536 { resolutionTiers.append(1536) }
            if maxDim > 1024 { resolutionTiers.append(1024) }
            if maxDim > 768  { resolutionTiers.append(768) }
            if maxDim > 512  { resolutionTiers.append(512) }
            
            for tier in resolutionTiers {
                let workingImage: PlatformImage = tier < maxDim ? Self.resizeImage(image: image, maxDimension: tier) : image
                
                var lo: CGFloat = 0.05
                var hi: CGFloat = 1.0
                var bestData: Data? = nil
                var bestQuality: CGFloat = 0
                
                for _ in 0..<8 {
                    let mid = (lo + hi) / 2
                    if let data = workingImage.jpegData(compressionQuality: mid) {
                        if data.count <= maxBytes {
                            bestData = data
                            bestQuality = mid
                            lo = mid
                        } else {
                            hi = mid
                        }
                    }
                }
                
                if let data = bestData {
                    if bestQuality >= 0.3 || tier <= 512 {
                        return data
                    }
                    continue
                }
            }
            
            let smallest = Self.resizeImage(image: image, maxDimension: 512)
            return smallest.jpegData(compressionQuality: 0.2)
        }
        
        nonisolated private static func resizeImage(image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
            #if os(iOS)
            let pixelW = image.size.width * image.scale
            let pixelH = image.size.height * image.scale
            #else
            let pixelW = image.size.width
            let pixelH = image.size.height
            #endif
            
            let currentMax = max(pixelW, pixelH)
            guard currentMax > maxDimension else { return image }
            
            let ratio = maxDimension / currentMax
            let newW = floor(pixelW * ratio)
            let newH = floor(pixelH * ratio)
            let newSize = CGSize(width: newW, height: newH)
            
            #if os(iOS)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = true
            format.scale = 1.0
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            return renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: newSize))
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
            #else
            let newImage = NSImage(size: newSize)
            newImage.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: newSize)).fill()
            image.draw(in: NSRect(origin: .zero, size: newSize))
            newImage.unlockFocus()
            return newImage
            #endif
        }
    }
}
