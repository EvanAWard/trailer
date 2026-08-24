import AppKit

/**
 Fills the Notifications tab of the preferences window with one sound popup per kind of notification.

 The rows are built here rather than in `PreferencesWindow.xib`, which holds only an empty container
 view for this tab. The pane holds no state of its own beyond the popup that belongs to each type.
 */
@MainActor
final class NotificationSoundsPane: NSObject {
    private static let labelWidth: CGFloat = 200
    private static let popupWidth: CGFloat = 200

    private var rows = [(type: NotificationType, popup: NSPopUpButton)]()

    init(container: NSView) {
        super.init()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
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
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor)
        ])

        reload()
    }

    /** Shows the stored sound in each popup, after a settings import or a reset replaced them. */
    func reload() {
        // Every row offers the same choices, so the titles are made once rather than per menu item.
        let all: [NotificationSound] = [.systemDefault] + NotificationSound.systemSounds() + [.silent]
        let sharedChoices = all.map { (title: $0.title, sound: $0) }

        for (type, popup) in rows {
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

    private func row(for type: NotificationType) -> NSView {
        let label = NSTextField(labelWithString: type.title)
        label.alignment = .right

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(soundSelected)
        rows.append((type, popup))

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 10

        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: NotificationSoundsPane.labelWidth),
            popup.widthAnchor.constraint(equalToConstant: NotificationSoundsPane.popupWidth)
        ])

        return row
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
}

/**
 A clip view with a flipped coordinate system, so a scroll view whose document view is not itself
 flipped (such as an `NSStackView`) still opens scrolled to the top of its content.
 */
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
