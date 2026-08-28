# An on/off switch for each notification category

Date: 2026-08-27
Branch: `feat/notification-customization`
Platform: macOS only

## Goal

The Notifications tab lets the user choose a sound for each of the 20 notification kinds. It does not
let the user stop a kind. Twelve of the 20 kinds have no on/off control anywhere in the app. This
design adds a checkbox for those twelve, in the tab that already lists them.

## Scope

This is a bounded change. It adds one setting per kind, one guard, and one column in a pane that
already exists. It adds no file, so it needs no edit of `project.pbxproj`.

A wider change was considered and rejected: move every notification master switch out of the Comments,
Reviews and Statuses tabs, so that the Notifications tab becomes the one place. That change is
architectural, and this document does not cover it. The reasons are recorded in
[Rejected: one tab for everything](#rejected-one-tab-for-everything).

## The twelve kinds that get a switch

| Group | Kinds |
|---|---|
| Comments | Mention |
| Pull requests | New PR, Re-Opened PR, Merged PR, Closed PR, PR Assigned |
| Issues | New Issue, Re-Opened Issue, Closed Issue, Issue Assigned |
| Repositories | New Repo Subscribed, New Repository |

Mention belongs in this list. `PRComment.processNotifications` posts a mention **before** it reads
`disableAllCommentNotifications`, so the comment master switch does not stop a mention.

## The eight kinds that keep no switch

Another tab already controls these. They keep their sound popup, and the row shows the name of that
tab in place of the checkbox.

| Row | Control today | Tab |
|---|---|---|
| Comment | `disableAllCommentNotifications`, plus the three comment pairs | Comments |
| Reaction | `notifyOnItemReactions`, `notifyOnCommentReactions` | Reactions |
| Review Requested | `notifyOnReviewAssignments` | Reviews |
| Team Review Requested | `notifyOnReviewAssignments` (the same setting) | Reviews |
| Changes Approved | `notifyOnReviewAcceptances` with `notifyOnAllReviewAcceptances` | Reviews |
| Changes Requested | `notifyOnReviewChangeRequests` with `notifyOnAllReviewChangeRequests` | Reviews |
| Review Dismissed | `notifyOnReviewDismissals` with `notifyOnAllReviewDismissals` | Reviews |
| PR Status Update | `notifyOnStatusUpdates` | Statuses |

## Storage

One key holds one kind:

```
NOTIFICATION_ENABLED_<rawValue>
```

The prefix and the raw values persist, so neither must change. This is the same shape as
`NOTIFICATION_SOUND_<rawValue>`.

Three functions go in `Shared/Settings.swift`, next to the sound functions. The getter and the setter
go **inside** the `#if os(macOS)` block, because only the macOS user interface and the macOS guard read
them:

```swift
static func notificationEnabled(for type: NotificationType) -> Bool
static func setNotificationEnabled(_ enabled: Bool, for type: NotificationType)
```

The key function goes **outside** that block, beside `notificationSoundKey`:

```swift
private static func notificationEnabledKey(for type: NotificationType) -> String
```

`allFields` is shared code, and it calls this function, so a key function inside the macOS block would
stop the iOS target from compiling. `notificationSoundKey` sits outside the block for the same reason.

The default is `true`, so an installation that upgrades keeps its present behaviour and no migration
is necessary.

The twelve keys join `Settings.allFields`, in the same way as the sound keys:

```swift
+ NotificationType.allCases.map(notificationSoundKey)
+ NotificationType.allCases.map(notificationEnabledKey)
```

`allFields` drives `writeToURL`, `readFromURL` and `resetAllSettings`, so this one line puts the new
keys into settings export, settings import and the reset.

The map covers all 20 kinds, not only the twelve. The eight other keys are never written, so they
never appear in an export. This costs nothing and keeps the line simple.

## Where the switch acts

One guard goes at the top of `NotificationManager.postNotification(type:for:)`:

```swift
#if os(macOS)
    guard Settings.notificationEnabled(for: type) else { return }
#endif
```

Three reasons for this position:

1. It is the one point that every notification passes through. The alternative is a guard at each of
   the 12 raise sites, in five shared files.
2. It keeps the bookkeeping correct. The sync sets `announced` on an item and `lastStatusNotified` on
   a pull request at the moment it queues a notification. A guard at a raise site would either skip
   that bookkeeping, and release a flood of old notifications when the user turns the kind back on, or
   duplicate it.
3. It sits before the guard clauses that build the content and before the avatar download, so a kind
   that is off costs nothing.

`PocketTrailer/NotificationManager.swift` compiles into both applications, but the guard is inside a
macOS-only block, so iOS behaviour does not change.

## User interface

`NotificationSoundsPane` builds each row. The row becomes four columns:

```
[checkbox]  Label............  [sound popup]  [hint]
```

- **checkbox**, 20pt wide. Present when the kind has its own switch.
- **label**, 200pt, right aligned. Unchanged.
- **sound popup**, 200pt. Unchanged, except that it is disabled while the checkbox is off.
- **hint**, trailing, small, in the secondary label colour. Present only when the kind has no
  checkbox. The pane composes the text from the tab name and the word `tab`, which gives `Reviews tab`.

A kind with no checkbox gets an empty view of the checkbox width, so every label stays in one column.

`reload()` reads the switch state as well as the sound, because a settings import or a reset replaces
both.

One property on `NotificationType` carries the mapping, in the macOS-only extension in
`Trailer/NotificationSounds.swift`, beside `title` and `group`:

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

One property answers both questions: whether the row has a checkbox, and what the hint says.

## Files touched

| File | Change |
|---|---|
| `Shared/Settings.swift` | The key function, the getter and the setter, and one line in `allFields`. |
| `Trailer/NotificationSounds.swift` | The `controlTabName` property on `NotificationType`. |
| `Trailer/NotificationSoundsPane.swift` | The checkbox column, the hint column, the action, and the read in `reload()`. |
| `PocketTrailer/NotificationManager.swift` | The guard, inside the existing macOS-only block. |

No new file. No change to the data model. No change to `Settings.Cache`, and therefore no change to
what the sync downloads.

## Notes and open points

- **`newRepoSubscribed` is dead.** No code posts it. `API.swift:364` posts `newRepoAnnouncement`, and
  nothing posts `newRepoSubscribed`. Its sound row exists today, so it gets a checkbox as well, to keep
  the pane consistent. Removing the case is a separate decision, and this design does not take it.
- **Review Requested and Team Review Requested share one setting.** `notifyOnReviewAssignments` decides
  both, so the user cannot keep one and stop the other. This design does not correct that, because the
  setting also feeds `Settings.Cache.shouldSyncReviewAssignments`, which the sync reads.
- **The pane name stays.** `NotificationSoundsPane` now shows more than sounds, but a rename of the file
  needs a hand edit of `project.pbxproj`, which is more risk than the name is worth.
- **A settings write arms the export timer.** This is the behaviour of every setting in the
  application, and this design does not change it. It matters when testing, because the settings suite
  holds live data.

## Verification

The project has no test target, so verification is a build and a manual pass.

1. `xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build`
2. `swiftlint` and `swiftformat .` from the repository root.
3. Open the Notifications tab. Confirm 12 rows have a checkbox and 8 rows show a tab name.
4. Turn off a kind, for example New PR. Confirm its sound popup goes grey.
5. Sync, and confirm that no notification of that kind arrives.
6. Turn the kind back on, and sync again. Confirm that no flood of old notifications arrives, because
   the sync marked those items as announced while the kind was off.
7. Export the settings, reset, and import. Confirm the switches come back.

## Rejected: one tab for everything

The Notifications tab could hold every master switch. It was rejected for this change, because it is
architectural rather than bounded:

- The eight settings are shared with iOS, and every one appears in
  `PocketTrailer/AdvancedSettingsViewController.swift`. Moving them removes function from a target
  that is out of scope.
- Three of them decide what the sync downloads. `Settings.Cache` computes `shouldSyncReactions`,
  `shouldSyncReviews` and `shouldSyncReviewAssignments` from them, and `V3API.swift:180` and
  `V4API.swift:53` read those flags. A switch that acts at delivery cannot do that work.
- The settings and the rows do not map one to one. Two reaction settings feed one row, one
  review-assignment setting feeds two rows, and six comment settings feed one row.
- The three review pairs are a three-way choice, not a master and a qualifier:
  `notifyOnAllReviewAcceptances || (notifyOnReviewAcceptances && createdByMe)` means off, my items, or
  all items.

The work would need six key migrations, a three-state mapping, edits to three tabs of
`PreferencesWindow.xib`, changes to `Settings.Cache`, and deletions in the iOS settings screen. That
needs its own design.
