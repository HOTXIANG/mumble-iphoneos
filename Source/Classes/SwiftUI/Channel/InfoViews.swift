//
//  InfoViews.swift
//  Mumble
//
//  User Info and Channel Info views with full HTML rendering.
//

import SwiftUI
import WebKit

// MARK: - HTML WebView (WKWebView wrapper for full HTML rendering)

/// 使用 WKWebView 渲染完整 HTML 富文本，支持格式、颜色、图片、链接等
struct HTMLContentView: PlatformViewRepresentable {
    let html: String
    @Binding var dynamicHeight: CGFloat
    
    #if os(macOS)
    typealias NSViewType = WKWebView
    
    func makeNSView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        loadHTML(in: webView)
    }
    #else
    typealias UIViewType = WKWebView
    
    func makeUIView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        loadHTML(in: webView)
    }
    #endif
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func createWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 允许内联播放、data URI 图片等
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        #if os(macOS)
        // macOS: 透明背景
        webView.setValue(false, forKey: "drawsBackground")
        #else
        // iOS: 透明背景
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        #endif
        
        return webView
    }
    
    private func loadHTML(in webView: WKWebView) {
        let fullHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                font-size: 14px;
                color: #e0e0e0;
                background: transparent;
                word-wrap: break-word;
                overflow-wrap: break-word;
                -webkit-text-size-adjust: none;
                padding: 4px 0;
                line-height: 1.5;
            }
            a { color: #58a6ff; text-decoration: underline; }
            a:hover { color: #79b8ff; }
            img {
                max-width: 100%;
                height: auto;
                border-radius: 6px;
                margin: 6px 0;
                display: block;
            }
            table {
                border-collapse: collapse;
                margin: 8px 0;
                width: 100%;
            }
            td, th {
                border: 1px solid rgba(255,255,255,0.15);
                padding: 6px 10px;
                text-align: left;
            }
            th { background: rgba(255,255,255,0.05); font-weight: 600; }
            pre, code {
                font-family: "SF Mono", Menlo, monospace;
                font-size: 13px;
                background: rgba(255,255,255,0.06);
                border-radius: 4px;
            }
            pre { padding: 10px; margin: 6px 0; overflow-x: auto; }
            code { padding: 2px 5px; }
            blockquote {
                border-left: 3px solid rgba(255,255,255,0.2);
                padding-left: 12px;
                margin: 6px 0;
                color: #aaa;
            }
            h1, h2, h3, h4, h5, h6 { margin: 8px 0 4px 0; }
            p { margin: 4px 0; }
            ul, ol { padding-left: 20px; margin: 4px 0; }
            hr { border: none; border-top: 1px solid rgba(255,255,255,0.15); margin: 8px 0; }
        </style>
        </head>
        <body>
        \(html)
        <script>
            // 通知 native 层内容高度
            function reportHeight() {
                var height = document.body.scrollHeight;
                window.webkit.messageHandlers.heightChanged.postMessage(height);
            }
            // 页面加载完成后、图片加载完成后都汇报高度
            reportHeight();
            window.addEventListener('load', reportHeight);
            document.querySelectorAll('img').forEach(function(img) {
                img.addEventListener('load', reportHeight);
                img.addEventListener('error', reportHeight);
            });
            // 监听 DOM 变化
            new MutationObserver(reportHeight).observe(document.body, {childList: true, subtree: true});
            // 延迟兜底
            setTimeout(reportHeight, 300);
            setTimeout(reportHeight, 1000);
        </script>
        </body>
        </html>
        """
        
        // 添加高度回调 handler
        let controller = webView.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        controller.add(webView.navigationDelegate as! WKScriptMessageHandler, name: "heightChanged")
        
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLContentView
        
        init(_ parent: HTMLContentView) {
            self.parent = parent
        }
        
        // 接收 JS 回报的高度
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightChanged", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    if height > 0 && abs(self.parent.dynamicHeight - height) > 1 {
                        self.parent.dynamicHeight = height
                    }
                }
            }
        }
        
        // 拦截链接点击，用系统浏览器打开
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

// MARK: - Platform Abstraction

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

// MARK: - User Info View

struct UserInfoView: View {
    let user: MKUser
    let isSelf: Bool
    
    @State private var comment: String = ""
    @State private var isEditing: Bool = false
    @State private var editText: String = ""
    @State private var isLoading: Bool = true
    @State private var contentHeight: CGFloat = 60
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 用户名头部
                    userHeader
                    
                    Divider().background(Color.white.opacity(0.2))
                    
                    // Comment 区域
                    if isEditing {
                        editingSection
                    } else {
                        displaySection
                    }
                }
                .padding()
            }
            #if os(macOS)
            .background(Color(.windowBackgroundColor).opacity(0.95))
            #endif
            .navigationTitle("User Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if isSelf && !isEditing {
                    ToolbarItem(placement: .automatic) {
                        Button("Edit") {
                            editText = comment
                            isEditing = true
                        }
                    }
                }
            }
        }
        .onAppear {
            loadComment()
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userCommentChangedNotification)) { notification in
            if let session = notification.userInfo?["userSession"] as? UInt,
               session == user.session() {
                if let c = user.comment() {
                    comment = c
                    isLoading = false
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
    
    // MARK: - Subviews
    
    private var userHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(user.userName() ?? "Unknown")
                    .font(.title2.bold())
                
                HStack(spacing: 8) {
                    if user.isAuthenticated() {
                        Label("Registered", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    if user.isSelfMuted() {
                        Label("Muted", systemImage: "mic.slash.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if user.isSelfDeafened() {
                        Label("Deafened", systemImage: "speaker.slash.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comment")
                .font(.headline)
                .foregroundColor(.secondary)
            
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if comment.isEmpty {
                Text("No comment set.")
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.vertical, 8)
            } else {
                HTMLContentView(html: comment, dynamicHeight: $contentHeight)
                    .frame(height: contentHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    
    @ViewBuilder
    private var editingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit Comment (HTML)")
                .font(.headline)
                .foregroundColor(.secondary)
            
            TextEditor(text: $editText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
            
            // 实时预览
            if !editText.isEmpty {
                Text("Preview")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HTMLContentView(html: editText, dynamicHeight: $contentHeight)
                    .frame(height: min(contentHeight, 300))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                    .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    isEditing = false
                }
                .buttonStyle(.bordered)
                
                Button("Save") {
                    saveComment()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadComment() {
        if let c = user.comment(), !c.isEmpty {
            comment = c
            isLoading = false
        } else if user.commentHash() != nil {
            // 只有 hash，需要向服务器请求完整 comment
            isLoading = true
            MUConnectionController.shared()?.serverModel?.requestComment(for: user)
        } else {
            // 没有 comment 也没有 hash
            comment = ""
            isLoading = false
        }
    }
    
    private func saveComment() {
        MUConnectionController.shared()?.serverModel?.setSelfComment(editText)
        comment = editText
        isEditing = false
    }
}

// MARK: - Channel Info View

struct ChannelInfoView: View {
    let channel: MKChannel
    
    @State private var descriptionText: String = ""
    @State private var isLoading: Bool = true
    @State private var contentHeight: CGFloat = 60
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 频道名头部
                    channelHeader
                    
                    Divider().background(Color.white.opacity(0.2))
                    
                    // Description 区域
                    descriptionSection
                }
                .padding()
            }
            #if os(macOS)
            .background(Color(.windowBackgroundColor).opacity(0.95))
            #endif
            .navigationTitle("Channel Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            loadDescription()
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.channelDescriptionChangedNotification)) { notification in
            if let channelId = notification.userInfo?["channelId"] as? UInt,
               channelId == channel.channelId() {
                if let desc = channel.channelDescription() {
                    descriptionText = desc
                    isLoading = false
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
    
    // MARK: - Subviews
    
    private var channelHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "number.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.channelName() ?? "Unknown")
                    .font(.title2.bold())
                
                let userCount = (channel.users() as? [MKUser])?.count ?? 0
                Text("\(userCount) user(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
                .foregroundColor(.secondary)
            
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if descriptionText.isEmpty {
                Text("No description set.")
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.vertical, 8)
            } else {
                HTMLContentView(html: descriptionText, dynamicHeight: $contentHeight)
                    .frame(height: contentHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadDescription() {
        if let desc = channel.channelDescription(), !desc.isEmpty {
            descriptionText = desc
            isLoading = false
        } else if channel.channelDescriptionHash() != nil {
            // 只有 hash，需要向服务器请求完整 description
            isLoading = true
            MUConnectionController.shared()?.serverModel?.requestDescription(for: channel)
        } else {
            descriptionText = ""
            isLoading = false
        }
    }
}
