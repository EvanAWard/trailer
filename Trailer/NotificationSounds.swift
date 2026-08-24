import AppKit
import UserNotifications

/** The sound that Trailer plays for one kind of notification. */
enum NotificationSound: Equatable {
    /** The alert sound that the user selected in System Settings. */
    case systemDefault
    /** No sound at all. */
    case silent
    /** A sound file, held as its name with the extension, for example `Ping.aiff`. */
    case named(String)

    /** The stored value that stands for `silent`. No system sound carries this name. */
    private static let silentMarker = "none"

    init(storedValue: String?) {
        guard let storedValue, !storedValue.isEmpty else {
            self = .systemDefault
            return
        }
        self = storedValue == NotificationSound.silentMarker ? .silent : .named(storedValue)
    }

    /** The value to write to `UserDefaults`. These strings persist, so they must not change. */
    var storedValue: String {
        switch self {
        case .systemDefault: ""
        case .silent: NotificationSound.silentMarker
        case let .named(name): name
        }
    }

    /** The name of the sound file without its extension, for example `Ping`. */
    private var baseName: String {
        switch self {
        case .silent, .systemDefault: ""
        case let .named(name): URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
    }

    /** The text that the popup shows. */
    var title: String {
        switch self {
        case .systemDefault: "Default"
        case .silent: "None"
        case .named: baseName
        }
    }

    /**
     The sound to attach to the notification content, after the file is put where the notification centre
     can find it. `nil` gives a silent notification.

     A sound that cannot be installed falls back to the default, so that the user still hears something.
     */
    func prepared() -> UNNotificationSound? {
        switch self {
        case .systemDefault: .default
        case .silent: nil
        case let .named(name):
            NotificationSoundLibrary.install(name)
                ? UNNotificationSound(named: UNNotificationSoundName(name))
                : .default
        }
    }

    /** Plays the sound, so that the user hears the selection in the preferences. */
    func play() {
        switch self {
        case .systemDefault:
            NSSound.beep()
        case .silent:
            break
        case .named:
            NSSound(named: baseName)?.play()
        }
    }

    /**
     The sounds that macOS supplies, in name order.

     The folder is read on each call, so an OS update that adds or removes a sound needs no change here.
     */
    static func systemSounds() -> [NotificationSound] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: NotificationSoundLibrary.systemSoundsFolder,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)) ?? []
        return contents
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { .named($0) }
    }
}

extension NotificationType {
    /** The heading under which the preferences show a kind of notification. */
    enum Group: CaseIterable {
        case comments, pullRequests, issues, reviews, statuses, repositories

        var title: String {
            switch self {
            case .comments: "Comments"
            case .pullRequests: "Pull requests"
            case .issues: "Issues"
            case .reviews: "Reviews"
            case .statuses: "Statuses"
            case .repositories: "Repositories"
            }
        }
    }

    /** The text that labels the row in the preferences. It is not the title of the notification. */
    var title: String {
        switch self {
        case .newComment: "Comment"
        case .newMention: "Mention"
        case .newReaction: "Reaction"
        case .newPr: "New PR"
        case .prReopened: "Re-Opened PR"
        case .prMerged: "Merged PR"
        case .prClosed: "Closed PR"
        case .newPrAssigned: "PR Assigned"
        case .newIssue: "New Issue"
        case .issueReopened: "Re-Opened Issue"
        case .issueClosed: "Closed Issue"
        case .newIssueAssigned: "Issue Assigned"
        case .assignedForReview: "Review Requested"
        case .assignedToTeamForReview: "Team Review Requested"
        case .changesApproved: "Changes Approved"
        case .changesRequested: "Changes Requested"
        case .changesDismissed: "Review Dismissed"
        case .newStatus: "PR Status Update"
        case .newRepoSubscribed: "New Repo Subscribed"
        case .newRepoAnnouncement: "New Repository"
        }
    }

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
