import SwiftUI

private let messageLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

func makeMessageBodyAttributedString(text: String) -> AttributedString {
    var attributedText = AttributedString(text)
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

    messageLinkDetector?.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
        guard let result,
              let url = result.url,
              let stringRange = Range(result.range, in: text),
              let attributedRange = Range(stringRange, in: attributedText) else { return }
        attributedText[attributedRange].link = url
    }

    return attributedText
}

struct MessageBodyTextView: View {
    let text: String
    let isSentBySelf: Bool

    var body: some View {
        let attributedText = makeMessageBodyAttributedString(text: text)
        #if os(macOS)
        MacMessageTextView(attributedText: attributedText, isSentBySelf: isSentBySelf)
        #else
        IOSMessageTextView(attributedText: attributedText, isSentBySelf: isSentBySelf)
        #endif
    }
}

#if os(macOS)
import AppKit

struct MacMessageTextView: NSViewRepresentable {
    let attributedText: AttributedString
    let isSentBySelf: Bool

    func makeNSView(context: Context) -> MessageNSTextView {
        MessageNSTextView()
    }

    func updateNSView(_ nsView: MessageNSTextView, context: Context) {
        nsView.setMessage(attributedText, isSentBySelf: isSentBySelf)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageNSTextView, context: Context) -> CGSize? {
        nsView.messageSize(fitting: proposal.width)
    }
}

final class MessageNSTextView: NSTextView {
    private var displayedMessage: AttributedString?
    private var displayedSentBySelf = false

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        linkTextAttributes = [
            .foregroundColor: NSColor.systemPink,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMessage(_ message: AttributedString, isSentBySelf: Bool) {
        // AppKit 会规范化存储属性；按上次输入判断，避免刷新时清掉选区。
        guard displayedMessage != message || displayedSentBySelf != isSentBySelf else { return }
        let attributedText = NSMutableAttributedString(attributedString: NSAttributedString(message))
        attributedText.addAttributes([
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isSentBySelf ? NSColor.white : NSColor.labelColor
        ], range: NSRange(location: 0, length: attributedText.length))

        textStorage?.setAttributedString(attributedText)
        displayedMessage = message
        displayedSentBySelf = isSentBySelf
    }

    func messageSize(fitting proposedWidth: CGFloat?) -> CGSize {
        guard let textContainer, let layoutManager else { return .zero }
        let naturalBounds = attributedString().boundingRect(
            with: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let naturalWidth = max(1, ceil(naturalBounds.width))
        let availableWidth = proposedWidth.flatMap { $0.isFinite ? max(1, $0) : nil }
        let width = min(naturalWidth, availableWidth ?? naturalWidth)
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        // 短消息按内容收窄，长消息按聊天区域宽度换行。
        return CGSize(width: width, height: ceil(usedRect.height))
    }
}
#endif
