import CoreData
import Lista
import TrailerJson
import TrailerQL

/**
 The review requests which one scan of one server has collected, keyed by pull request. The answer
 pages the requests of a pull request, so one page holds only part of the list, and the whole list is
 applied when the scan ends.
 */
final class ReviewRequestCollector {
    private(set) var userLogins = [PullRequest: Set<String>]()
    private(set) var teamSlugs = [PullRequest: Set<String>]()
    /** The pull requests which the answer named, including any which no request names. */
    private(set) var pullRequests = Set<PullRequest>()

    /** Records that the answer named this pull request, which an empty list must also do. */
    func noteRequest(for pr: PullRequest) {
        pullRequests.insert(pr)
    }

    func add(login: String, for pr: PullRequest) {
        userLogins[pr, default: []].insert(login)
        pullRequests.insert(pr)
    }

    func add(teamSlug: String, for pr: PullRequest) {
        teamSlugs[pr, default: []].insert(teamSlug)
        pullRequests.insert(pr)
    }
}

final class Review: DataItem {
    @NSManaged var body: String?
    @NSManaged var username: String?
    @NSManaged var state: String?
    /** The login of whoever dismissed this review. GitHub does not carry it on the review itself, so a sync path which reads no events leaves it nil. */
    @NSManaged var dismisserName: String?

    @NSManaged var pullRequest: PullRequest
    @NSManaged var comments: Set<PRComment>

    override static var typeName: String {
        "Review"
    }

    enum State: String {
        case CHANGES_REQUESTED
        case APPROVED
        case DISMISSED
    }

    /** Reads one page of review requests into the collector. */
    static func collectRequests(from nodes: Lista<Node>, into collector: ReviewRequestCollector, moc: NSManagedObjectContext, parentCache: FetchCache) {
        for node in nodes {
            guard let parentId = node.parent?.id,
                  let parent = PullRequest.asParent(with: parentId, in: moc, parentCache: parentCache),
                  let reviewerJson = node.jsonPayload.potentialObject(named: "requestedReviewer") else {
                continue
            }

            if let login = reviewerJson.potentialString(named: "login") {
                collector.add(login: login, for: parent)
            }
            if let slug = reviewerJson.potentialString(named: "slug") {
                collector.add(teamSlug: slug, for: parent)
            }
        }
    }

    /** Applies the collected requests, which must hold every page, one time for each pull request. */
    static func applyRequests(from collector: ReviewRequestCollector, settings: Settings.Cache) {
        for pr in collector.pullRequests {
            pr.checkAndStoreReviewAssignments(collector.userLogins[pr] ?? [],
                                              collector.teamSlugs[pr] ?? [],
                                              settings: settings)
        }
    }

    static func sync(from nodes: Lista<Node>, on server: ApiServer, moc: NSManagedObjectContext, parentCache: FetchCache) {
        syncItems(of: Review.self, from: nodes, on: server, moc: moc, parentCache: parentCache) { review, node in
            let info = node.jsonPayload
            if (try? info.keys)?.count == 3 { // this node is a blank container (id, comments, typename)
                return
            }
            let newState = info.potentialString(named: "state")
            review.check(newState: newState)

            guard node.created || node.updated,
                  let parentId = node.parent?.id
            else { return }

            if node.created {
                if let parent = PullRequest.asParent(with: parentId, in: moc, parentCache: parentCache) {
                    review.pullRequest = parent
                } else {
                    Task {
                        await Logging.shared.log("Warning Review without parent")
                    }
                }
            }

            review.body = info.potentialString(named: "body")
            review.username = info.potentialObject(named: "author")?.potentialString(named: "login")
        }
    }

    override var asReview: Review? {
        self
    }

    @MainActor
    static func syncReviews(from data: [TypedJson.Entry]?, withParent: PullRequest, moc: NSManagedObjectContext) async {
        let parentId = withParent.objectID
        let apiServerId = withParent.apiServer.objectID
        await v3items(with: data, type: Review.self, serverId: apiServerId, moc: moc) { item, info, isNewOrUpdated, syncMoc in
            if isNewOrUpdated, let parent = try? syncMoc.existingObject(with: parentId) as? PullRequest {
                item.pullRequest = parent
                item.body = info.potentialString(named: "body")
                item.username = info.potentialObject(named: "user")?.potentialString(named: "login")
            }
            let newState = info.potentialString(named: "state")
            item.check(newState: newState)
        }
    }

    private func check(newState: String?) {
        if state != newState { // state change doesn't change API date, so we need to check for this every time
            state = newState
            if postSyncAction == PostSyncAction.doNothing.rawValue {
                postSyncAction = PostSyncAction.isUpdated.rawValue
            }
        }
    }

    func processNotifications(settings: Settings.Cache) {
        guard pullRequest.canBadge(settings: settings), let newState = State(rawValue: state.orEmpty) else {
            return
        }

        switch newState {
        case .CHANGES_REQUESTED:
            if !isMine, settings.notifyOnAllReviewChangeRequests || (settings.notifyOnReviewChangeRequests && pullRequest.createdByMe) {
                NotificationQueue.add(type: .changesRequested, for: self)
            }
        case .APPROVED:
            if !isMine, settings.notifyOnAllReviewAcceptances || (settings.notifyOnReviewAcceptances && pullRequest.createdByMe) {
                NotificationQueue.add(type: .changesApproved, for: self)
            }
        case .DISMISSED:
            // A review holds its author, not whoever dismissed it, so a dismissal I make myself notifies too.
            if isMine {
                if settings.notifyOnMyReviewDismissals {
                    NotificationQueue.add(type: .myReviewDismissed, for: self)
                }
            } else if settings.notifyOnAllReviewDismissals || (settings.notifyOnReviewDismissals && pullRequest.createdByMe) {
                NotificationQueue.add(type: .changesDismissed, for: self)
            }
        }
    }

    static func review(with id: Int, in moc: NSManagedObjectContext) -> Review? {
        let f = NSFetchRequest<Review>(entityName: "Review")
        f.returnsObjectsAsFaults = false
        f.includesSubentities = false
        f.fetchLimit = 1
        f.predicate = NSPredicate(format: "serverId == %d", id)
        return try! moc.fetch(f).first
    }

    var isMine: Bool {
        username == apiServer.userName
    }

    var affectsBottomLine: Bool {
        switch state {
        case State.APPROVED.rawValue, State.CHANGES_REQUESTED.rawValue, State.DISMISSED.rawValue:
            true
        default:
            false
        }
    }
}
