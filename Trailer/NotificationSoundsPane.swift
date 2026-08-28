import AppKit

/**
 Fills the Notifications tab of the preferences window with a header naming the columns and one row
 per kind of notification. Each row shows a sound popup, then an on/off checkbox for the kinds this
 tab controls, or the name of the tab that controls the kind instead.

 The rows are built here rather than in `PreferencesWindow.xib`, which holds only an empty container
 view for this tab.
 */
@MainActor
final class NotificationSoundsPane: NSObject {
    private static let labelWidth: CGFloat = 200
    private static let popupWidth: CGFloat = 200
    /** The left and right inset of the rows. The header uses it too, so the columns line up. */
    private static let horizontalInset: CGFloat = 20

    private var rows = [(type: NotificationType, popup: NSPopUpButton, checkbox: NSButton?)]()

    init(container: NSView) {
        super.init()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6,
                                        left: NotificationSoundsPane.horizontalInset,
                                        bottom: 14,
                                        right: NotificationSoundsPane.horizontalInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let typesByGroup = Dictionary(grouping: NotificationType.allCases, by: \.group)

        for group in NotificationType.Group.allCases {
            let heading = NSTextField(labelWithString: group.title)
            heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            stack.addArrangedSubview(heading)

            for type in typesByGroup[group] ?? [] {
                stack.addArrangedSubview(row(for: type))
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedClipView()
        scroll.contentView = clip
        scroll.documentView = stack

        // The header sits outside the scroll view, so it stays in view while the rows scroll under it.
        let header = headerRow()
        container.addSubview(header)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: NotificationSoundsPane.horizontalInset),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // A zero-frame `NSBox` has no intrinsic height and picks its axis from its bounds, so state both.
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor)
        ])

        reload()
    }

    /** Shows the stored sound and switch state in each row, after a settings import or a reset replaced them. */
    func reload() {
        // Every row offers the same choices, so the titles are made once rather than per menu item.
        let all: [NotificationSound] = [.systemDefault] + NotificationSound.systemSounds() + [.silent]
        let sharedChoices = all.map { (title: $0.title, sound: $0) }

        for (type, popup, checkbox) in rows {
            checkbox?.state = Settings.notificationEnabled(for: type) ? .on : .off

            let current = Settings.notificationSound(for: type)
            var choices = sharedChoices
            if !choices.contains(where: { $0.sound == current }) {
                // An OS update removed the file. Keep the name, so the row still shows the selection.
                choices.insert((current.title, current), at: choices.count - 1)
            }

            let menu = NSMenu()
            for choice in choices {
                let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                item.representedObject = choice.sound
                menu.addItem(item)
            }
            popup.menu = menu
            popup.selectItem(at: choices.firstIndex { $0.sound == current } ?? 0)
        }
    }

    /** A dimmed small label, used for the column names and for the hint that replaces a checkbox. */
    private static func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    /** Lays out the three columns of the header and of every row, so the columns cannot drift. */
    private static func columnStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10

        NSLayoutConstraint.activate([
            views[0].widthAnchor.constraint(equalToConstant: labelWidth),
            views[1].widthAnchor.constraint(equalToConstant: popupWidth)
        ])

        return stack
    }

    /** Names the popup and checkbox columns. */
    private func headerRow() -> NSView {
        let header = NotificationSoundsPane.columnStack([
            NSView(),
            NotificationSoundsPane.secondaryLabel("Sound"),
            NotificationSoundsPane.secondaryLabel("Notify")
        ])
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    private func row(for type: NotificationType) -> NSView {
        let label = NSTextField(labelWithString: type.title)
        label.alignment = .right

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(soundSelected)

        // A kind that another tab controls names that tab in place of the checkbox.
        let trailing: NSView
        let checkbox: NSButton?
        if let controlTabName = type.controlTabName {
            trailing = NotificationSoundsPane.secondaryLabel("\(controlTabName) tab")
            checkbox = nil
        } else {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledToggled))
            button.setAccessibilityLabel(type.title)
            trailing = button
            checkbox = button
        }

        rows.append((type, popup, checkbox))

        return NotificationSoundsPane.columnStack([label, popup, trailing])
    }

    @objc
    private func soundSelected(_ sender: NSPopUpButton) {
        guard let type = rows.first(where: { $0.popup === sender })?.type,
              let sound = sender.selectedItem?.representedObject as? NotificationSound else { return }

        Settings.setNotificationSound(sound, for: type)
        // The preview reads the system folder directly, so install now to log a failure while the user is here.
        _ = sound.prepared()
        sound.play()
    }

    @objc
    private func enabledToggled(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.checkbox === sender }) else { return }

        let enabled = sender.state == .on
        Settings.setNotificationEnabled(enabled, for: row.type)
    }
}

/**
 A clip view with a flipped coordinate system, so a scroll view whose document view is not itself
 flipped (such as an `NSStackView`) still opens scrolled to the top of its content.
 */
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
