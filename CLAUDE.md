# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Trailer: a GitHub pull-request/issue monitor. One Xcode project (`Trailer.xcodeproj`) builds a macOS
menu-bar app, an iOS/iPadOS app, a watchOS app, and a macOS login-item helper, all on top of one shared
Core Data + sync core. This repo is a fork of `ptsochantaris/trailer` (`origin` is `EvanAWard/trailer`).

## Commands

```sh
# macOS app
xcodebuild -project Trailer.xcodeproj -scheme Trailer -destination 'platform=macOS' build

# iOS app (embeds the watch app)
xcodebuild -project Trailer.xcodeproj -scheme PocketTrailer -destination 'generic/platform=iOS' build

swiftlint            # config: .swiftlint.yml (run from repo root)
swiftlint analyze    # needed for the `explicit_self` rule, which is an analyzer rule
swiftformat .        # config: .swiftformat, language version from .swift-version (6.2)
```

Notes that will save you a cycle:

- The project file is `objectVersion = 90` and is built with **Xcode 26.3**. Third-party pbxproj tooling
  (the ruby `xcodeproj` gem, XcodeGen, Tuist) targets much older versions and will rewrite the file into
  the legacy shape — edit it by hand or from Xcode, not with those tools.
- First build resolves eight remote SPM packages, so it needs network.
- SwiftLint runs as a build phase on the `Trailer` and `PocketTrailer` targets, but the script is
  `if which swiftlint`, so it silently no-ops when the tool is missing.
- `.swiftlint.yml` deliberately disables `line_length`, `file_length`, `function_body_length`,
  `type_body_length`, `force_cast`, `force_try`, `cyclomatic_complexity` and more. Do not "fix" long
  files or long functions for lint's sake.
- `.swiftformat` sets `-header ""`: files carry no header comments.
- Launching either app with the `-useSystemLog` argument routes the internal log to `os_log`. Otherwise
  logging is a no-op unless the in-app monitor is open (macOS `ApiMonitorWindow`, iOS `LogMonitor`).
- Language mode is Swift 5 (`SWIFT_VERSION = 5.0`) even though the toolchain is Swift 6.
  Deployment targets: macOS 12.4, iOS 16.0, watchOS 8.7.

## Targets and how code is shared

| Target | Notes |
|---|---|
| `Trailer` | macOS menu-bar app. `LSUIElement`, XIB-based UI, Sparkle auto-update. |
| `TrailerLauncher` | Tiny macOS helper embedded in `Trailer.app`, used for launch-at-login. |
| `PocketTrailer` | iOS/iPadOS app, storyboard-based. |
| `PocketTrailer WatchKit App` | watchOS app. Thin client — no database of its own. |

There is **no shared framework**. Files in `Shared/` (plus root-level `Logging.swift`, `ImageCache.swift`)
are compiled into each target by direct membership in that target's Sources build phase. **Adding a file
to `Shared/` does nothing until you add it to each target that needs it.** The watch target deliberately
includes only its own controllers plus `Enums.swift` and `compression.swift`.

The `PocketTrailer Today Extension` scheme in `xcshareddata/xcschemes` points at a target that no longer
exists. Ignore it; it will not build.

## Architecture

### Core Data stack

Model: `Shared/Trailer.xcdatamodeld`, 44 versions, currently `Trailer 44.xcdatamodel`. Migration is
lightweight/inferred (`NSMigratePersistentStoresAutomaticallyOption`). A model change means adding a new
`.xcdatamodel` version and bumping `.xccurrentversion` — never editing an existing version.

Store lives in `DataManager.dataFilesDirectory` (`Shared/DataManager.swift`): the
`group.com.EvanAWard.Trailer` app-group container on iOS, `~/Library/Application Support/<dataDirectoryName>`
on macOS, where `dataDirectoryName` is in `Shared/Globals.swift`. It is deliberately **not**
`com.housetrip.Trailer`, so this fork does not share a database with an installed release Trailer.
That macOS path is the developer's **live** database — treat it as production data.

Context discipline matters here:

- `DataManager.main` is the **only** context attached to the persistent store (main queue).
- Everything else is a child via `NSManagedObjectContext.buildChildContext()`, normally through
  `DataManager.runInChild(of:block:)`, which saves the child on exit — pushing changes into the parent,
  *not* to disk.
- `DataManager.saveDB()` is the only path that writes to disk, and it also drives Spotlight indexing.
- `API.performSync` builds its own main-queue child `syncMoc` on top of `DataManager.main`, so a failed
  sync can be discarded without touching committed data.

### The postSyncAction state machine

This is the centre of the whole design (`Shared/DataItem.swift`, `Shared/API.swift`):

1. Before syncing, surviving rows are flagged `PostSyncAction.delete`.
2. As the server confirms each row it becomes `.doNothing`, `.isUpdated`, or `.isNew`.
3. Anything still flagged `.delete` afterwards is deleted by `DataItem.nukeDeletedItems`, followed by
   `nukeOrphanedItems` for comments/labels/statuses/reviews/reactions that lost their parent.
4. Per-server failures roll back only that server's changes (`ApiServer.rollBackAllUpdates`), so a broken
   server never wipes its own items.
5. `DataManager.sendNotificationsIndexAndSave` reads the same flags to decide notifications, snooze
   wake-ups, and auto-removal, then clears them.

If items are disappearing or duplicating, this flag lifecycle is where to look.

### Two API paths

`Settings.useV4API` selects between them; both converge on the same entities and the same flag lifecycle.

- **v3 REST** — `Shared/RestAccess.swift` (`@RestActor`) + `Shared/V3API.swift`. Link-header paging,
  upserts keyed on `node_id` via `DataItem.v3items(...)`.
- **v4 GraphQL** — `Shared/GraphQL.swift` + `Shared/V4API.swift`, built on the TrailerQL package's
  `Query`/`Fragment`/`Group`/`Field` result builders. Page sizes and query cost ceilings come from
  `GraphQL.Profile` (`light`/`cautious`/`moderate`/`high`); `Settings.threadedSync` opts into two
  parallel queries. `Settings.V4IdMigrationPhase` + `GraphQL.migrateV4Ids` handle GitHub's new global
  node IDs (`X-Github-Next-Global-ID`).

All HTTP goes through `HTTP` (`Shared/HTTP.swift`, `@HTTPActor`) and is throttled by a Semalot ticket
gate (`HTTP.gateKeeper`, 8 tickets).

### Item classification — where display behaviour is decided

`ListableItem.postProcess(settings:)` (`Shared/ListableItem.swift`) computes an item's `sectionIndex`
from repo policies, review state, snoozing, labels, authors, and draft status. `Section` lives in
`Shared/Enums.swift` (`mine`, `participated`, `mentioned`, `merged`, `closed`, `all`, `snoozed`, and
`hidden(cause:)` which carries a `HidingCause` explaining *why* — that's what the "hidden items" scan UI
displays). Unread/total comment counts are computed in the same pass.

Every list in every platform is then just a fetch request from
`ListableItem.requestForItems(of:withFilter:sectionIndex:criterion:settings:)` filtering on `sectionIndex`.
**So when an item shows up in the wrong place, fix `postProcess`/`highestPreferredSection`, not the UI.**

### Settings and the settings cache

Settings live in `UserDefaults(suiteName: appGroupIdentifier)` — `group.com.EvanAWard.Trailer`
(`Shared/Globals.swift`) — behind property wrappers in
`Shared/Settings.swift` (`@UserDefault`, `@OptionalUserDefault`, `@EnumUserDefault`,
`@MovePlacementUserDefault`, `@AssignmentPlacementUserDefault`). Conventions:

- Each setting usually has a paired `static let ...Help` string, consumed by both platforms' prefs UI.
- Any write recreates `Settings.cache`, an immutable `Settings.Cache` snapshot.
- Sync and post-processing functions take an explicit `settings: Settings.Cache` parameter and thread it
  through. Follow that — do not read `Settings.foo` inside sync/post-process loops, because one sync pass
  must see one consistent configuration.
- Legacy/renamed keys are migrated in `Settings.checkMigration()`, called from `bootUp()` in
  `Shared/Globals.swift` alongside `DataManager.checkMigration()` and `API.setup()`.

### Concurrency model

Most of the data and UI layer is `@MainActor` (`DataManager`, `API`, `GraphQL`). I/O is pushed onto
dedicated global actors: `HTTPActor`, `RestActor`. `Logging.shared` and `ImageCache.shared` are actors,
which is why synchronous code is littered with `Task { await Logging.shared.log(...) }` — that pattern is
intentional, not sloppiness.

### Credentials

`ApiServer.authToken` is **not** stored in Core Data. It reads and writes the keychain through the
`keyVine` global in `Shared/Globals.swift` (KeyVine package, access group `com.housetrip.Trailer`, team
`63VU3T7V3Q`, shared by the macOS and iOS apps). Tokens found in the old Core Data field are migrated to
the keychain on first access and the field is blanked.

`keyVine` is a `nonisolated(unsafe) var`, so it is replaceable.

## Platform UI

**macOS** — `MacAppDelegate.setupWindows()` builds one `MenuBarSet` per `GroupingCriterion` (one per repo
`groupLabel`, plus one per API server when `Settings.showSeparateApiServersInMenu`, plus an ungrouped
fallback). Each `MenuBarSet` owns a PR menu and an Issues menu (`MenuWindow` from `MenuWindow.xib`) with
its own `NSStatusItem` drawn by `StatusItemView`. `GroupingCriterion` (`Shared/GroupingCriterion.swift`)
is the predicate glue that scopes a menu to a server or a repo group. Preferences are one large
`PreferencesWindow.xib` plus `PreferencesWindow.swift`.

**iOS** — storyboards (`Main.storyboard`, `PocketTrailer/PocketTrailer/Base.lproj/Settings.storyboard`,
`Quickstart.storyboard`). `SectionListViewController` renders tabs derived from `TabInfo.items(for:)`,
using the same `GroupingCriterion` values as the Mac menus. Background refresh is a `BGProcessingTask`
registered as `com.housetrip.mobile.trailer.ios.PocketTrailer.refresh`. URL scheme: `pockettrailer`.

**watchOS** — the watch app has no database. `CommonController.send(request:)` sends WatchConnectivity
messages; the iOS side answers in `PocketTrailer/WatchManager.swift` by querying Core Data and returning
plist-safe dictionaries, and writes an overview blob into the app-group container for complications.
Any watch feature therefore needs matching changes on both sides.

## Dependencies

Upstream `ptsochantaris/*` packages, several of which were split out of this codebase: **TrailerQL**
(GraphQL DSL), **TrailerJson** (`TypedJson.Entry` and its `potentialString/potentialInt/potentialObject`
accessors — all JSON parsing goes through these), **Lista** (linked list used on hot paths),
**Semalot** (ticket semaphore), **KeyVine** (keychain), **Maintini** (keeps the app alive during
background work), **PopTimer** (debounce). Plus **Sparkle** for macOS updates (macOS target only;
feed `https://ptsochantaris.github.io/trailer/appcast.xml`).

## Conventions and gotchas

- New `DataItem` subclasses must override `class var typeName`; the `Querying` protocol extension keys all
  its fetch helpers (`allItems`, `newOrUpdatedItems`, `items(surviving:)`, `item(id:)`, …) off it.
- `DataItem.parseGH8601` is a hand-rolled `strptime` parser guarded by an unfair lock, used instead of
  `ISO8601DateFormatter` for speed. Leave it alone unless you are profiling.
- Enums that are persisted as raw `Int` (`Section`, `ItemCondition`, `PostSyncAction`, `RepoDisplayPolicy`,
  …) precompute `NSPredicate` arrays for their cases. Preserve the existing raw values; stored data and
  exported settings depend on them.
- Platform differences are handled with `#if os(iOS)` / `#elseif os(macOS)` and the `COLOR_CLASS`,
  `FONT_CLASS`, `IMAGE_CLASS` typealiases (`Shared/Colors.swift`, `Shared/Globals.swift`), plus a global
  `app` weak reference to whichever app delegate is in play.
- The macOS store and the settings suite hold the developer's **live** data. A settings *write* also
  arms an export timer that can overwrite a real file. Never point throwaway code at either one.
- `DataManager.main` is a lazy `static var`: its initialiser runs on the first access of any kind,
  including a write. Assigning to it does not dodge the real store.
- `Section.==` deliberately ignores the `HidingCause` payload, so `.hidden(cause: .a) == .hidden(cause: .b)`
  is **true**. Pattern-match the cause out when you need it.
- `Section.HidingCause` is not `CaseIterable`. Cases must be listed by hand.
- `HidingCause.hidingMyAuthoredIssues`'s description reads `"IRepo setting: ssue authored by me"` — a
  transposition. Correct it only on purpose.
- `SortingMethod`'s field names are Core Data attribute names, so they are not free text. Changing one
  changes the fetch it drives.
- `Shared/compression.swift` is not compiled into the macOS target (iOS and watch only). Its decompress
  loop spins forever on truncated input.
