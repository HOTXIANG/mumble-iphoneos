import SwiftUI
import UIKit

// Exercises production UIKit text logic through Mac Catalyst on the host.
// Native touch gestures and the long-press menu still require device UI testing.
@main
struct IOSMessageTextTests {
    @MainActor
    static func main() {
        let view = MessageUITextView()
        precondition(!view.isEditable && view.isSelectable && !view.isScrollEnabled)
        precondition(view.textContainerInset == .zero)
        precondition(view.textContainer.lineFragmentPadding == 0)

        let text = "😀 前文 https://example.com/path?q=1 后文"
        let message = makeMessageBodyAttributedString(text: text)
        let linkLocation = (text as NSString).range(of: "https://").location
        view.setMessage(message, isSentBySelf: false)
        precondition(view.attributedText.string == text)
        precondition(view.attributedText.attribute(.link, at: linkLocation, effectiveRange: nil) as? URL
            == URL(string: "https://example.com/path?q=1"))
        precondition(view.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .label)
        precondition(view.attributedText.attribute(.foregroundColor, at: linkLocation, effectiveRange: nil) as? UIColor == .systemPink)
        precondition(view.attributedText.attribute(.underlineStyle, at: linkLocation, effectiveRange: nil) as? Int
            == NSUnderlineStyle.single.rawValue)
        precondition((view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize == 17)

        view.selectedRange = NSRange(location: linkLocation, length: 10)
        let selection = view.selectedRange
        _ = view.messageSize(fitting: 100)
        view.setMessage(makeMessageBodyAttributedString(text: text), isSentBySelf: false)
        precondition(view.selectedRange == selection, "An unchanged message must preserve native selection")
        view.setMessage(message, isSentBySelf: true)
        precondition(view.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .white)
        precondition(view.attributedText.attribute(.foregroundColor, at: linkLocation, effectiveRange: nil) as? UIColor == .systemPink)

        view.setMessage(AttributedString("Hi"), isSentBySelf: false)
        let short = view.messageSize(fitting: 250)
        precondition(short.width > 0 && short.width < 50 && short.height > 0)
        precondition(view.messageSize(fitting: nil) == short)
        precondition(view.messageSize(fitting: .infinity) == short)

        let longURL = "https://example.com/" + String(repeating: "path/", count: 50)
        view.setMessage(makeMessageBodyAttributedString(text: longURL), isSentBySelf: false)
        let wide = view.messageSize(fitting: 250)
        let narrow = view.messageSize(fitting: 100)
        precondition(wide.width <= 250 && narrow.width <= 100)
        precondition(narrow.height > wide.height && wide.height > short.height)
        precondition(view.attributedText.string == longURL)

        view.setMessage(AttributedString("one\ntwo\n"), isSentBySelf: false)
        let multiline = view.messageSize(fitting: 250)
        precondition(multiline.width < 50 && multiline.height > short.height * 2)
        view.setMessage(AttributedString("\n"), isSentBySelf: false)
        let newline = view.messageSize(fitting: 250)
        precondition(newline.width > 0 && newline.height > 0)
        print("iOS message text: Catalyst native logic checks passed (touch interactions not exercised)")
    }
}
