import UIKit
import WebKit

/// A public keyboard layout guide anchors the row without altering WebKit responder classes.
@MainActor
final class TerminalKeyRow: UIView {
    weak var page: WKWebView?
    var onVisibility: ((Bool) -> Void)?
    private var terminalFocused = false
    private var composing = false
    private var keyboardVisible = false
    private var sticky = false
    private var buttons: [UIButton] = []
    private var observers: [NSObjectProtocol] = []

    init(page: WKWebView) {
        self.page = page
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        let scroll = UIScrollView()
        let stack = UIStackView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 4
        addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        let keys = [("Esc", "\u{1B}"), ("Tab", "\t"), ("Ctrl", ""), ("↑", "\u{1B}[A"), ("↓", "\u{1B}[B"),
                    ("←", "\u{1B}[D"), ("→", "\u{1B}[C"), ("|", "|"), ("~", "~"), ("/", "/"), ("-", "-")]
        for (title, data) in keys {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.widthAnchor.constraint(equalToConstant: 48).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.press(title: title, data: data) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        for event in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.keyboardChanged(notification) }
            })
        }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func detach() { for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll() }

    func update(_ state: [String: Bool]) {
        terminalFocused = state["focused"] == true
        composing = state["composing"] == true
        if state["sticky"] == false || !terminalFocused || composing { sticky = false }
        for button in buttons { button.isEnabled = !composing }
        buttons.first { $0.title(for: .normal) == "Ctrl" }?.backgroundColor = sticky ? .systemBlue.withAlphaComponent(0.2) : .clear
        refresh()
    }

    private func keyboardChanged(_ notification: Notification) {
        if notification.name == UIResponder.keyboardDidHideNotification { keyboardVisible = false }
        else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window = window {
            let local = window.convert(frame, from: nil)
            keyboardVisible = window.bounds.intersection(local).height > 90
        }
        refresh()
    }

    private func refresh() {
        let visible = terminalFocused && keyboardVisible
        isHidden = !visible
        if !visible {
            sticky = false
            page?.evaluateJavaScript("window.harnessStickyControl = false", completionHandler: nil)
        }
        onVisibility?(visible)
    }

    private func press(title: String, data: String) {
        guard terminalFocused, keyboardVisible, !composing, let page else { return }
        if title == "Ctrl" {
            sticky.toggle()
            buttons.first { $0.title(for: .normal) == "Ctrl" }?.backgroundColor = sticky ? .systemBlue.withAlphaComponent(0.2) : .clear
            page.evaluateJavaScript("window.harnessStickyControl = \(sticky ? "true" : "false")", completionHandler: nil)
            return
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: [data]),
              let argument = String(data: encoded, encoding: .utf8) else { return }
        page.evaluateJavaScript("window.harnessSendTerminal?.(\(argument)[0])", completionHandler: nil)
    }

    static let bridgeScript = """
    (() => {
      let composing = false;
      const terminal = () => document.activeElement?.closest('.xterm');
      const report = () => window.webkit.messageHandlers.terminalState.postMessage({
        focused: !!terminal(), composing, sticky: !!window.harnessStickyControl
      });
      window.harnessSendTerminal = data => {
        const root = terminal();
        if (!root || composing || typeof root.harnessTerminalInput !== 'function') return false;
        root.harnessTerminalInput(data);
        window.harnessStickyControl = false;
        report(); return true;
      };
      document.addEventListener('focusin', report);
      document.addEventListener('focusout', () => setTimeout(report, 0));
      document.addEventListener('compositionstart', () => {
        composing = true; window.harnessStickyControl = false; report();
      }, true);
      document.addEventListener('compositionend', () => { composing = false; report(); }, true);
      document.addEventListener('beforeinput', event => {
        if (!terminal() || composing || event.isComposing || !window.harnessStickyControl) return;
        const value = event.data;
        if (event.inputType !== 'insertText' || typeof value !== 'string' || value.length !== 1) return;
        const code = value.toUpperCase().charCodeAt(0);
        if (code < 64 || code > 95) return;
        event.preventDefault(); window.harnessSendTerminal(String.fromCharCode(code & 31));
      }, true);
    })();
    """
}
