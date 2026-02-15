//
//  RichTextEditorShell.swift
//  Mumble
//
//  Extracted HTML shell for WYSIWYG editor.
//

import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension WYSIWYGEditorView {
    func loadEditorShell(in webView: WKWebView) {
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
}
