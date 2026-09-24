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
    /** The gap between the columns of the header and of every row. */
    private static let columnSpacing: CGFloat = 10
    /** The left and right inset of the rows. The header uses it too, so the columns line up. */
    private static let horizontalInset: CGFloat = 20
    /** The vertical gap between the headings and rows of the scrolling list. */
    private static let rowSpacing: CGFloat = 6
    private static let listTopInset: CGFloat = 6
    private static let listBottomInset: CGFloat = 14

    private var rows = [(type: NotificationType, popup: NSPopUpButton, checkbox: NSButton?)]()

    init(container: NSView) {
        super.init()

        let typesByGroup = Dictionary(grouping: NotificationType.allCases, by: \.group)

        var items = [NSView]()
        for group in NotificationType.Group.allCases {
            let heading = NSTextField(labelWithString: group.title)
            heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            heading.sizeToFit()
            items.append(heading)

            for type in typesByGroup[group] ?? [] {
                items.append(row(for: type))
            }
        }

        // The document view is flipped, so the list is laid out from the top down.
        let doc = FlippedView()
        var y = NotificationSoundsPane.listTopInset
        for (index, item) in items.enumerated() {
            if index > 0 {
                y += NotificationSoundsPane.rowSpacing
            }
            item.setFrameOrigin(NSPoint(x: NotificationSoundsPane.horizontalInset, y: y))
            doc.addSubview(item)
            y += item.frame.height
        }
        doc.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: y + NotificationSoundsPane.listBottomInset)
        doc.autoresizingMask = .width

        // The header sits outside the scroll view, so it stays in view while the rows scroll under it.
        // The container is not flipped, so the header and separator are placed down from its top edge.
        let header = headerRow()
        header.setFrameOrigin(NSPoint(x: NotificationSoundsPane.horizontalInset,
                                      y: container.bounds.height - 14 - header.frame.height))
        header.autoresizingMask = .minYMargin
        container.addSubview(header)

        let separator = NSBox(frame: NSRect(x: 0, y: header.frame.minY - 6 - 1, width: container.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        container.addSubview(separator)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: container.bounds.width, height: separator.frame.minY))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = doc
        container.addSubview(scroll)

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
    private static func columnRow(_ views: [NSView]) -> NSView {
        for case let control as NSControl in views {
            control.sizeToFit()
        }
        views[0].frame.size.width = labelWidth
        views[1].frame.size.width = popupWidth

        let row = NSView()
        let height = views.map(\.frame.height).max() ?? 0
        var x: CGFloat = 0
        for view in views {
            view.setFrameOrigin(NSPoint(x: x, y: (height - view.frame.height) / 2))
            row.addSubview(view)
            x += view.frame.width + columnSpacing
        }
        row.frame = NSRect(x: 0, y: 0, width: x - columnSpacing, height: height)

        return row
    }

    /** Names the popup and checkbox columns. */
    private func headerRow() -> NSView {
        NotificationSoundsPane.columnRow([
            NSView(),
            NotificationSoundsPane.secondaryLabel("Sound"),
            NotificationSoundsPane.secondaryLabel("Notify")
        ])
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

        return NotificationSoundsPane.columnRow([label, popup, trailing])
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
 A view with a flipped coordinate system. As the document view of a scroll view, it opens scrolled to
 the top of its content and keeps the top in place when the scroll view is resized.
 */
private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
