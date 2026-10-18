#if os(iOS)
import SwiftUI
import UIKit

/// 由 UIKit 处理链接打开、文字选择和系统复制菜单。
struct IOSMessageTextView: UIViewRepresentable {
    let attributedText: AttributedString
    let isSentBySelf: Bool

    func makeUIView(context: Context) -> MessageUITextView {
        let textView = MessageUITextView()
        textView.setMessage(attributedText, isSentBySelf: isSentBySelf)
        return textView
    }

    func updateUIView(_ uiView: MessageUITextView, context: Context) {
        uiView.setMessage(attributedText, isSentBySelf: isSentBySelf)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MessageUITextView,
        context: Context
    ) -> CGSize? {
        uiView.messageSize(fitting: proposal.width)
    }
}

final class MessageUITextView: UITextView {
    private var displayedMessage: AttributedString?
    private var displayedSentBySelf = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        contentInset = .zero
        adjustsFontForContentSizeCategory = false
        dataDetectorTypes = []
        linkTextAttributes = [
            .foregroundColor: UIColor.systemPink,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func messageSize(fitting proposedWidth: CGFloat?) -> CGSize {
        // 短消息按内容收窄，长消息按聊天区域宽度换行。
        let naturalBounds = attributedText.boundingRect(
            with: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let naturalWidth = max(1, ceil(naturalBounds.width))
        let constrainedWidth = proposedWidth.flatMap { $0.isFinite ? max(1, $0) : nil }
        let width = min(naturalWidth, constrainedWidth ?? naturalWidth)
        let fittedSize = sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fittedSize.height))
    }

    func setMessage(_ message: AttributedString, isSentBySelf: Bool) {
        // SwiftUI 更新周边状态时不要重置选区和正在显示的系统菜单。
        guard displayedMessage != message || displayedSentBySelf != isSentBySelf else { return }
        let nativeText = NSMutableAttributedString(attributedString: NSAttributedString(message))
        let fullRange = NSRange(location: 0, length: nativeText.length)
        nativeText.addAttributes([
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: isSentBySelf ? UIColor.white : UIColor.label
        ], range: fullRange)
        nativeText.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            nativeText.addAttributes([
                .foregroundColor: UIColor.systemPink,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }

        attributedText = nativeText
        displayedMessage = message
        displayedSentBySelf = isSentBySelf
    }
}
#endif
