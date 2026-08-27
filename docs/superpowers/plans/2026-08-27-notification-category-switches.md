# Notification Category Switches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on/off switch for each of the twelve notification kinds that have no on/off control anywhere in the macOS application, and show which other tab controls the eight kinds that do.

**Architecture:** One `UserDefaults` key per kind, `NOTIFICATION_ENABLED_<rawValue>`, read by one guard at the top of `NotificationManager.postNotification(type:for:)` and written by a new checkbox column in the Notifications preferences pane. A new `controlTabName` property on `NotificationType` answers both "does this row get a checkbox" and "which tab name does the hint show".

**Tech Stack:** Swift 5 language mode on the Swift 6.2 toolchain, AppKit, `UserNotifications`, Xcode 26.3, SwiftLint, SwiftFormat.

**Spec:** `docs/superpowers/specs/2026-08-27-notification-category-switches-design.md`

## Global Constraints

- **macOS only.** In scope: the `Trailer` target and the macOS half of `Shared/`. Do not build, run or
  change the `PocketTrailer` (iOS) or `PocketTrailer WatchKit App` (watchOS) targets.
- **Shared code must stay correct.** `Shared/Settings.swift` and
  `PocketTrailer/NotificationManager.swift` compile into the iOS target as well. Every new symbol that
  shared code calls must sit outside an `#if os(macOS)` block.
- **No new file.** Every change goes into one of four files that already exist. Do not edit
  `Trailer.xcodeproj/project.pbxproj`.
- **The storage key prefix is exactly** `NOTIFICATION_ENABLED_`, joined to `type.rawValue`.
- **The default is `true`**, so an installation that upgrades keeps its present behaviour. Write no
  migration.
- **The pane file keeps its name.** Do not rename `NotificationSoundsPane.swift` or its class.
- **No test target exists.** Verification for every task is a build, plus SwiftLint and SwiftFormat.
  Do not add a test target, and do not write `XCTest` files.
- **The macOS settings suite holds the developer's live data**, and a settings write arms the export
  timer. Do not point throwaway code at `UserDefaults(suiteName: "group.com.eaw.Trailer")`.

### The build and lint commands, used by every task

```sh
xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build
swiftlint
swiftformat .
```

Run all three from the repository root. The first build of a clean checkout resolves eight remote SPM
packages, so it needs network and takes several minutes.

---

## File Structure

| File | Responsibility after this change |
|---|---|
| `Shared/Settings.swift` | Holds the key function, the getter, the setter, and the `allFields` entry. Shared with iOS: the key function must stay outside `#if os(macOS)`. |
| `Trailer/NotificationSounds.swift` | Holds `controlTabName`, beside `title` and `group`, in the macOS-only extension on `NotificationType`. |
| `PocketTrailer/NotificationManager.swift` | Holds the one guard, inside the existing macOS-only conditional style used in this file. |
| `Trailer/NotificationSoundsPane.swift` | Builds the four-column row, stores the checkbox per row, and reads the switch state in `reload()`. |

The dependency order is Settings → (`controlTabName`, guard) → pane. Task 4 needs both Task 1 and
Task 2, so keep the order below.

---

## Task 1: The stored setting

**Files:**
- Modify: `Shared/Settings.swift:205` (the `allFields` return) and `Shared/Settings.swift:1011-1026`
  (the notification sounds section)
- Test: none. The project has no test target. Verification is a build.

**Interfaces:**
- Consumes: `NotificationType` and its `rawValue` (`Shared/Enums.swift`), already used by
  `notificationSoundKey`.
- Produces:
  - `private static func notificationEnabledKey(for type: NotificationType) -> String` — outside
    `#if os(macOS)`, callable from `allFields`.
  - `static func notificationEnabled(for type: NotificationType) -> Bool` — macOS only. Returns `true`
    when nothing is stored.
  - `static func setNotificationEnabled(_ enabled: Bool, for type: NotificationType)` — macOS only.

- [ ] **Step 1: Add the key function, the getter and the setter**

Open `Shared/Settings.swift`. Find the notification sounds section, which today reads:

```swift
    //////////////////////// Notification sounds

    /** The key that holds the sound for one kind of notification. The prefix persists, so it must not change. */
    private static func notificationSoundKey(for type: NotificationType) -> String {
        "NOTIFICATION_SOUND_" + type.rawValue
    }

    #if os(macOS)
        static func notificationSound(for type: NotificationType) -> NotificationSound {
            NotificationSound(storedValue: Settings[notificationSoundKey(for: type)] as? String)
        }

        static func setNotificationSound(_ sound: NotificationSound, for type: NotificationType) {
            Settings[notificationSoundKey(for: type)] = sound.storedValue
        }
    #endif
```

Replace that whole block with:

```swift
    //////////////////////// Notification sounds

    /** The key that holds the sound for one kind of notification. The prefix persists, so it must not change. */
    private static func notificationSoundKey(for type: NotificationType) -> String {
        "NOTIFICATION_SOUND_" + type.rawValue
    }

    /** The key that holds the on/off switch for one kind of notification. The prefix persists, so it must not change. */
    private static func notificationEnabledKey(for type: NotificationType) -> String {
        "NOTIFICATION_ENABLED_" + type.rawValue
    }

    #if os(macOS)
        static func notificationSound(for type: NotificationType) -> NotificationSound {
            NotificationSound(storedValue: Settings[notificationSoundKey(for: type)] as? String)
        }

        static func setNotificationSound(_ sound: NotificationSound, for type: NotificationType) {
            Settings[notificationSoundKey(for: type)] = sound.storedValue
        }

        /** Whether Trailer posts this kind of notification. Nothing stored means on, so an upgrade keeps its behaviour. */
        static func notificationEnabled(for type: NotificationType) -> Bool {
            Settings[notificationEnabledKey(for: type)] as? Bool ?? true
        }

        static func setNotificationEnabled(_ enabled: Bool, for type: NotificationType) {
            Settings[notificationEnabledKey(for: type)] = enabled
        }
    #endif
```

Two points that matter, both from the spec:

- `notificationEnabledKey` sits **outside** `#if os(macOS)`, because `allFields` is shared code and
  calls it. A key function inside the block stops the iOS target from compiling.
- The getter falls back to `true`, not `false`.

- [ ] **Step 2: Add the keys to `allFields`**

Find the end of the `allFields` array, at `Shared/Settings.swift:205`:

```swift
        ] + NotificationType.allCases.map(notificationSoundKey)
```

Change it to:

```swift
        ] + NotificationType.allCases.map(notificationSoundKey)
            + NotificationType.allCases.map(notificationEnabledKey)
```

`allFields` drives `writeToURL`, `readFromURL` and `resetAllSettings`, so this line alone puts the new
keys into settings export, settings import and the reset.

The map covers all 20 kinds, not only the twelve that get a checkbox. The other eight keys are never
written, so they never appear in an export. This is deliberate, and it keeps the line simple.

- [ ] **Step 3: Build**

Run:

```sh
xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`.

If the build fails with "cannot find 'notificationEnabledKey' in scope" inside `allFields`, the key
function was put inside the `#if os(macOS)` block. Move it out.

- [ ] **Step 4: Lint and format**

Run:

```sh
swiftlint
swiftformat .
```

Expected: SwiftLint reports no violation in `Shared/Settings.swift`. SwiftFormat may reindent the new
lines. If it changes anything, keep its output.

- [ ] **Step 5: Commit**

```bash
git add Shared/Settings.swift
git commit -m "Store an on/off switch for each notification kind"
```

---

## Task 2: The tab that controls each kind

**Files:**
- Modify: `Trailer/NotificationSounds.swift`, in the `extension NotificationType` block, after `group`
  (which ends near line 147)
- Test: none. Verification is a build.

**Interfaces:**
- Consumes: the `NotificationType` cases listed in `title` and `group` in the same file.
- Produces: `var controlTabName: String? { get }` on `NotificationType`, macOS only, because
  `Trailer/NotificationSounds.swift` belongs to the `Trailer` target alone.

`nil` means the Notifications tab holds the control, so the row gets a checkbox. A name means another
tab holds it, so the row gets a hint instead. Task 4 reads this property for both decisions.

- [ ] **Step 1: Add the property**

Open `Trailer/NotificationSounds.swift`. The `extension NotificationType` block ends with `group`:

```swift
    var group: Group {
        switch self {
        case .newComment, .newMention, .newReaction: .comments
        case .newPr, .prReopened, .prMerged, .prClosed, .newPrAssigned: .pullRequests
        case .newIssue, .issueReopened, .issueClosed, .newIssueAssigned: .issues
        case .assignedForReview, .assignedToTeamForReview, .changesApproved, .changesRequested, .changesDismissed: .reviews
        case .newStatus: .statuses
        case .newRepoSubscribed, .newRepoAnnouncement: .repositories
        }
    }
}
```

Add this property after `group`, inside the same extension, before the closing brace:

```swift
    /**
     The preferences tab that holds the on/off control for this kind.

     `nil` means the Notifications tab holds it, so the row shows a checkbox.
     */
    var controlTabName: String? {
        switch self {
        case .newComment: "Comments"
        case .newReaction: "Reactions"
        case .assignedForReview, .assignedToTeamForReview,
             .changesApproved, .changesRequested, .changesDismissed: "Reviews"
        case .newStatus: "Statuses"
        default: nil
        }
    }
```

The eight kinds named here are exactly the eight that another tab already controls. Note that
`.newMention` is **not** in the list: `PRComment.processNotifications` posts a mention before it reads
`disableAllCommentNotifications`, so the comment master switch does not stop a mention. Mention gets a
checkbox.

`default: nil` covers the other twelve. Keep it, rather than listing them: the spec writes it this way,
and a new `NotificationType` case then gets a checkbox by default.

- [ ] **Step 2: Build**

Run:

```sh
xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`. Nothing calls `controlTabName` yet, so the compiler only checks
that the cases exist.

- [ ] **Step 3: Lint and format**

Run:

```sh
swiftlint
swiftformat .
```

Expected: no violation in `Trailer/NotificationSounds.swift`.

- [ ] **Step 4: Commit**

```bash
git add Trailer/NotificationSounds.swift
git commit -m "Name the tab that controls each notification kind"
```

---

## Task 3: The guard that stops a notification

**Files:**
- Modify: `PocketTrailer/NotificationManager.swift:108`, the first line of
  `postNotification(type:for:)`
- Test: none. Verification is a build, then the manual pass in Task 5.

**Interfaces:**
- Consumes: `Settings.notificationEnabled(for:)` from Task 1.
- Produces: nothing that a later task calls.

Despite its path, this file compiles into the `Trailer` target as well as the iOS target. That is why
the guard must sit inside `#if os(macOS)`.

- [ ] **Step 1: Add the guard**

Open `PocketTrailer/NotificationManager.swift`. The function starts:

```swift
    func postNotification(type: NotificationType, for item: DataItem) async {
        let notification = UNMutableNotificationContent()

        switch type {
```

Insert the guard as the first statement:

```swift
    func postNotification(type: NotificationType, for item: DataItem) async {
        #if os(macOS)
            guard Settings.notificationEnabled(for: type) else { return }
        #endif

        let notification = UNMutableNotificationContent()

        switch type {
```

This position is deliberate, for three reasons from the spec:

1. It is the one point that every notification passes through. A guard at each of the twelve raise
   sites would touch five shared files.
2. It keeps the bookkeeping correct. The sync sets `announced` on an item, and `lastStatusNotified` on
   a pull request, at the moment it queues a notification. A guard at a raise site would either skip
   that bookkeeping, and so release a flood of old notifications when the user turns the kind back on,
   or duplicate it.
3. It sits before the guard clauses that build the content and before the avatar download, so a kind
   that is off costs nothing.

Do not move the guard below the `switch`, and do not add a second guard anywhere else.

- [ ] **Step 2: Build**

Run:

```sh
xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Lint and format**

Run:

```sh
swiftlint
swiftformat .
```

Expected: no violation in `PocketTrailer/NotificationManager.swift`. SwiftFormat indents the body of an
`#if` block by four spaces in this repository, which the snippet above already shows.

- [ ] **Step 4: Commit**

```bash
git add PocketTrailer/NotificationManager.swift
git commit -m "Stop a notification whose kind is switched off"
```

---

## Task 4: The checkbox and the hint in the Notifications tab

**Files:**
- Modify: `Trailer/NotificationSoundsPane.swift` — the `rows` property, `reload()`, `row(for:)`, and a
  new action method
- Test: none. Verification is a build, then the manual pass in Task 5.

**Interfaces:**
- Consumes: `Settings.notificationEnabled(for:)` and `Settings.setNotificationEnabled(_:for:)` from
  Task 1; `NotificationType.controlTabName` from Task 2.
- Produces: nothing that a later task calls.

The row becomes four columns:

```
[checkbox]  Label............  [sound popup]  [hint]
```

- **checkbox**, 20pt wide, present when `controlTabName` is `nil`.
- **label**, 200pt, right aligned. Unchanged.
- **sound popup**, 200pt. Unchanged, except that it is disabled while the checkbox is off.
- **hint**, trailing, small, in the secondary label colour, present only when `controlTabName` is not
  `nil`. The text is the tab name and the word `tab`, which gives `Reviews tab`.

A kind with no checkbox gets an empty view of the checkbox width, so every label stays in one column.

- [ ] **Step 1: Widen the row record and add the checkbox width**

The pane holds one record per row. Today it is a pair. It becomes a triple, so that both the action and
`reload()` can find the checkbox. The checkbox is optional, because eight rows have none.

Change:

```swift
    private static let labelWidth: CGFloat = 200
    private static let popupWidth: CGFloat = 200

    private var rows = [(type: NotificationType, popup: NSPopUpButton)]()
```

to:

```swift
    private static let labelWidth: CGFloat = 200
    private static let popupWidth: CGFloat = 200
    private static let checkboxWidth: CGFloat = 20

    private var rows = [(type: NotificationType, popup: NSPopUpButton, checkbox: NSButton?)]()
```

- [ ] **Step 2: Build the four-column row**

Replace the whole of `row(for:)`:

```swift
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
```

with:

```swift
    private func row(for type: NotificationType) -> NSView {
        let label = NSTextField(labelWithString: type.title)
        label.alignment = .right

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(soundSelected)

        let controlTabName = type.controlTabName

        // A kind that another tab controls keeps an empty view of the same width, so every label stays in one column.
        let leading: NSView
        let checkbox: NSButton?
        if controlTabName == nil {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledToggled))
            leading = button
            checkbox = button
        } else {
            leading = NSView()
            checkbox = nil
        }

        rows.append((type, popup, checkbox))

        let row = NSStackView(views: [leading, label, popup])
        row.orientation = .horizontal
        row.spacing = 10

        if let controlTabName {
            let hint = NSTextField(labelWithString: "\(controlTabName) tab")
            hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            hint.textColor = .secondaryLabelColor
            row.addArrangedSubview(hint)
        }

        NSLayoutConstraint.activate([
            leading.widthAnchor.constraint(equalToConstant: NotificationSoundsPane.checkboxWidth),
            label.widthAnchor.constraint(equalToConstant: NotificationSoundsPane.labelWidth),
            popup.widthAnchor.constraint(equalToConstant: NotificationSoundsPane.popupWidth)
        ])

        return row
    }
```

`NSView()` from code has `translatesAutoresizingMaskIntoConstraints` set to `true`, but `NSStackView`
turns that off for every view it arranges, so the width constraint above holds for the empty view as
well as for the checkbox.

- [ ] **Step 3: Read the switch state in `reload()`**

`reload()` runs after a settings import or a reset, which replaces the switch as well as the sound. It
must therefore set both.

In `reload()`, change the loop head and add the checkbox work. The loop today reads:

```swift
        for (type, popup) in rows {
            let current = Settings.notificationSound(for: type)
```

Change it to:

```swift
        for (type, popup, checkbox) in rows {
            let enabled = Settings.notificationEnabled(for: type)
            checkbox?.state = enabled ? .on : .off
            popup.isEnabled = checkbox == nil || enabled

            let current = Settings.notificationSound(for: type)
```

Leave the rest of the loop body, which builds the menu, exactly as it is.

`popup.isEnabled` is `true` for the eight rows that have no checkbox, because those kinds keep their
sound choice. It follows the stored switch for the other twelve.

- [ ] **Step 4: Add the action**

Add this method after `soundSelected`:

```swift
    @objc
    private func enabledToggled(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.checkbox === sender }) else { return }

        let enabled = sender.state == .on
        Settings.setNotificationEnabled(enabled, for: row.type)
        row.popup.isEnabled = enabled
    }
```

Leave `soundSelected` unchanged. Its lookup names the tuple members:

```swift
        guard let type = rows.first(where: { $0.popup === sender })?.type,
```

so it still compiles against the three-member record.

- [ ] **Step 5: Build**

Run:

```sh
xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`.

A failure of the form "tuple type ... is not convertible to tuple type ..." means one `rows.append`
still passes two members. Every append must pass three.

- [ ] **Step 6: Lint and format**

Run:

```sh
swiftlint
swiftformat .
```

Expected: no violation in `Trailer/NotificationSoundsPane.swift`.

- [ ] **Step 7: Commit**

```bash
git add Trailer/NotificationSoundsPane.swift
git commit -m "Switch a notification kind on or off from the Notifications tab"
```

---

## Task 5: The manual verification pass

**Files:** none. This task changes no code. It confirms the four earlier tasks together.

**Interfaces:**
- Consumes: everything from Tasks 1 to 4.
- Produces: nothing.

The project has no test target, so this pass is the only functional check. Run it with the application
built from the working tree. Steps 5 and 6 need a GitHub server configured in the application, and a
sync that finds at least one new item.

> **Warning.** The macOS store and the settings suite hold the developer's live data, and a settings
> write arms the export timer.

- [ ] **Step 1: Build and launch**

Run:

```sh
xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build
```

Then open the built `Trailer.app` from the derived data path that the build prints, and open the
preferences window.

- [ ] **Step 2: Count the rows in the Notifications tab**

Open the Notifications tab. Confirm:

- Twelve rows carry a checkbox: Mention; New PR, Re-Opened PR, Merged PR, Closed PR, PR Assigned;
  New Issue, Re-Opened Issue, Closed Issue, Issue Assigned; New Repo Subscribed, New Repository.
- Eight rows carry no checkbox and show a tab name instead: Comment shows `Comments tab`; Reaction shows
  `Reactions tab`; Review Requested, Team Review Requested, Changes Approved, Changes Requested and
  Review Dismissed each show `Reviews tab`; PR Status Update shows `Statuses tab`.
- Every label lines up in one column, whether or not its row has a checkbox.

- [ ] **Step 3: Turn a kind off**

Clear the New PR checkbox. Confirm that its sound popup goes grey, and that no other row changes.

- [ ] **Step 4: Confirm the switch stops the notification**

Leave New PR off. Sync, so that the application finds at least one new pull request. Confirm that no
New PR notification arrives, and that notifications of other kinds still arrive.

- [ ] **Step 5: Confirm no flood when the kind comes back**

Set the New PR checkbox. Sync again. Confirm that no flood of old New PR notifications arrives, because
the sync marked those items as announced while the kind was off. This is the point of putting the guard
in `postNotification` rather than at the raise sites.

- [ ] **Step 6: Confirm export and import carry the switches**

Turn two kinds off, for example Merged PR and New Issue. Then:

1. Export the settings to a file.
2. Copy that file, and delete every `NOTIFICATION_ENABLED_` entry from the copy. Import the copy, and
   confirm every checkbox in the Notifications tab is now set, which is the `true` default for a
   settings file that predates this change.
3. Import the original export.
4. Confirm Merged PR and New Issue are clear again, and that the sound selections came back too.

This exercises the `allFields` line from Task 1 and the read in `reload()` from Task 4 together.

- [ ] **Step 7: Report**

Report each step as pass or fail, with what you saw. If a step failed, say which, and do not report the
work as complete.
