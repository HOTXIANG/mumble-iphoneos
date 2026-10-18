import AppKit
import SwiftUI

@main
@MainActor
struct MessageTextTests {
    private static var failures: [String] = []

    static func main() {
        _ = NSApplication.shared
        checkLinkAttributes()
        checkNativeSelectionAndCopy()
        checkMessageSizing()
        checkHostedMessageSizing()

        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
        print("Message text: all native link, selection, copy, and layout checks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        if !condition() { failures.append(description) }
    }

    private static func makeTextView(_ text: String) -> MessageNSTextView {
        let view = MessageNSTextView()
        view.setMessage(makeMessageBodyAttributedString(text: text), isSentBySelf: false)
        return view
    }

    private static func checkRenderedLayout(_ view: MessageNSTextView, fitting width: CGFloat, description: String) {
        let size = view.messageSize(fitting: width)
        view.frame = CGRect(origin: .zero, size: size)
        guard let container = view.textContainer, let manager = view.layoutManager else {
            failures.append("\(description): native layout manager is missing")
            return
        }
        manager.ensureLayout(for: container)
        let renderedRect = manager.usedRect(for: container)
        check(renderedRect.maxY <= view.bounds.height + 0.5,
              "\(description): assigning the measured frame must not clip text vertically")
        check(renderedRect.maxX <= view.bounds.width + 0.5,
              "\(description): assigning the measured frame must not overflow horizontally")
        check(manager.glyphRange(for: container).length == manager.numberOfGlyphs,
              "\(description): every message glyph must remain in the text container")
    }

    private static func checkLinkAttributes() {
        // Emoji and non-ASCII characters before and inside a URL exercise the
        // UTF-16 ranges returned by NSDataDetector.
        let text = "前缀🙂 https://example.com/路径 www.example.org person@example.com 后缀"
        let view = makeTextView(text)
        check(!view.isEditable && view.isSelectable, "Messages must remain read-only and selectable")
        check(view.string == text, "Detecting links must preserve the original displayed text")
        guard let storage = view.textStorage else {
            failures.append("Native message text storage is missing")
            return
        }

        let expectedLinks: [(String, URL)] = [
            ("https://example.com/路径", URL(string: "https://example.com/路径")!),
            ("www.example.org", URL(string: "http://www.example.org")!),
            ("person@example.com", URL(string: "mailto:person@example.com")!)
        ]
        var linkRuns: [(NSRange, URL)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value else { return }
            guard let url = value as? URL else {
                failures.append("Native link values must be URLs usable by AppKit")
                return
            }
            linkRuns.append((range, url))
        }
        check(linkRuns.count == expectedLinks.count, "All URL, www, and email links must become native links")
        for (label, expectedURL) in expectedLinks {
            let expectedRange = (text as NSString).range(of: label)
            check(linkRuns.contains { $0.0 == expectedRange && $0.1 == expectedURL },
                  "Wrong native link range or destination for \(label)")
        }
        check(storage.attribute(.link, at: 0, effectiveRange: nil) == nil,
              "Normal message text must not inherit a link")
        check((view.linkTextAttributes?[.cursor] as? NSCursor) == NSCursor.pointingHand,
              "Native links must advertise the pointing-hand cursor")
        check((view.linkTextAttributes?[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue,
              "Native links must remain visually distinguishable")
        storage.enumerateAttribute(.cursor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            check(value == nil, "The hand cursor must be scoped to link attributes, not the whole message")
        }
    }

    private static func checkNativeSelectionAndCopy() {
        let text = "复制🙂 https://example.com/路径 后面的文字"
        let message = makeMessageBodyAttributedString(text: text)
        let view = makeTextView(text)
        let selection = (text as NSString).range(of: "example.com/路径")
        view.setSelectedRange(selection)
        view.setMessage(message, isSentBySelf: false)
        check(view.selectedRange() == selection, "An unchanged SwiftUI update must preserve the selected substring")

        // Native copy uses the user's general pasteboard. Save and restore all
        // available item formats, including non-text clipboard contents.
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        defer {
            pasteboard.clearContents()
            let restoredItems = previousItems.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
        }
        view.copy(nil)
        check(pasteboard.string(forType: .string) == "example.com/路径",
              "Native copy must copy only the selected substring, including Unicode")
        check(view.selectedRange() == selection, "Native copy must preserve the selection")
    }

    private static func checkMessageSizing() {
        let short = makeTextView("你好 hello")
        let shortSize = short.messageSize(fitting: 240)
        check(shortSize.width > 0 && shortSize.width < 240 && shortSize.height > 0,
              "Short messages must shrink to their text instead of filling the bubble")
        checkRenderedLayout(short, fitting: 240, description: "Short message")

        let multiline = makeTextView("第一行\n第二行\n第三行")
        let multilineSize = multiline.messageSize(fitting: 240)
        check(multilineSize.height > shortSize.height * 2,
              "Explicit line breaks must contribute to the message height")
        checkRenderedLayout(multiline, fitting: 240, description: "Multiline message")

        let longURL = "https://example.com/" + String(repeating: "abcdefghij", count: 24)
        let long = makeTextView(longURL)
        let narrow = long.messageSize(fitting: 120)
        let wide = long.messageSize(fitting: 420)
        let narrowAgain = long.messageSize(fitting: 120)
        check(narrow.width <= 120 && wide.width <= 420, "Long unbroken links must stay within the proposed width")
        check(narrow.height > wide.height && wide.height > shortSize.height,
              "Long unbroken links must wrap and reflow when the message width changes")
        check(narrowAgain == narrow, "Repeated width changes must not leave a stale text layout")
        checkRenderedLayout(long, fitting: 120, description: "Long link in a narrow chat area")
        checkRenderedLayout(long, fitting: 420, description: "Long link after widening the chat area")
        checkRenderedLayout(long, fitting: 120, description: "Long link after narrowing the chat area again")
        let idealSize = short.messageSize(fitting: nil)
        check(idealSize.width > 0 && idealSize.width < 240 && idealSize.height == shortSize.height,
              "An unspecified width must produce a compact ideal size for short messages")
    }

    private struct HostedMessage: View {
        let text: String
        let width: CGFloat

        var body: some View {
            HStack(alignment: .top) {
                MessageBodyTextView(text: text, isSentBySelf: false)
                    .padding(10)
                    .background(Color.gray.opacity(0.2))
                Spacer(minLength: 40)
            }
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func checkHostedMessageSizing() {
        let text = "https://example.com/" + String(repeating: "abcdefghij", count: 24)
        let host = NSHostingView(rootView: HostedMessage(text: text, width: 240))
        let narrowSize = host.fittingSize
        host.frame = CGRect(origin: .zero, size: narrowSize)
        host.layoutSubtreeIfNeeded()

        guard let native = firstTextView(in: host) else {
            failures.append("SwiftUI must host the native selectable message text view")
            return
        }
        check(native.frame.width > 0 && native.frame.width <= 180,
              "A hosted long URL must fit inside the message bubble and adjacent gap")
        let narrowHeight = native.frame.height
        check(narrowHeight > 30 && narrowSize.height >= narrowHeight,
              "SwiftUI must allocate the native message's full wrapped height")
        if let container = native.textContainer, let manager = native.layoutManager {
            manager.ensureLayout(for: container)
            check(manager.usedRect(for: container).maxY <= native.bounds.height + 0.5,
                  "The hosted narrow message frame must contain every rendered line")
        }

        host.rootView = HostedMessage(text: text, width: 520)
        let wideSize = host.fittingSize
        host.frame = CGRect(origin: .zero, size: wideSize)
        host.layoutSubtreeIfNeeded()
        check(native.frame.width > 180 && native.frame.width <= 460,
              "A hosted message must grow with a wider chat area")
        check(native.frame.height < narrowHeight,
              "A hosted message must reduce its wrapped height after widening")
        if let container = native.textContainer, let manager = native.layoutManager {
            manager.ensureLayout(for: container)
            check(manager.usedRect(for: container).maxY <= native.bounds.height + 0.5,
                  "The hosted wide message frame must contain every rendered line")
        }
    }

    private static func firstTextView(in view: NSView) -> MessageNSTextView? {
        if let textView = view as? MessageNSTextView { return textView }
        return view.subviews.lazy.compactMap { firstTextView(in: $0) }.first
    }
}
