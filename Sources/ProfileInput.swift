import AppKit

@MainActor
final class ProfileInput: NSView {
    let field: NSTextField
    private let pasteboard: NSPasteboard?
    private(set) lazy var pasteButton = NSButton(
        title: "Вставить из буфера",
        target: self,
        action: #selector(pasteFromClipboard)
    )

    init(secure: Bool, initialValue: String, pasteboard: NSPasteboard? = nil) {
        self.pasteboard = pasteboard
        field = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 58))
        field.stringValue = initialValue
        field.placeholderString = secure ? "vless://…" : "socks5://127.0.0.1:1080"
        field.setAccessibilityLabel(secure ? "Ссылка VLESS" : "Адрес прокси")

        pasteButton.keyEquivalent = "v"
        pasteButton.keyEquivalentModifierMask = [.command]
        let stack = NSStackView(views: [field, pasteButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func pasteFromClipboard() {
        guard let text = (pasteboard ?? .general).string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            NSSound.beep()
            return
        }
        if let editor = field.currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            field.validateEditing()
        } else {
            field.stringValue = text
            window?.makeFirstResponder(field)
        }
    }
}
