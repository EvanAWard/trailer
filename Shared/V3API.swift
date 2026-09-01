import CoreData
import Foundation
import TrailerJson

/**
 The review actors which one pass of the issue event scan collected. A dismissal is held here rather
 than applied at once, because a v3 review row is keyed on `serverId` and may not exist until the
 review fetch has run. This also enforces first-seen-wins for both actors, because the issue event
 stream this collector is fed from runs newest first, so the first match for a review or a pull
 request is the newest one and is the one that should be kept.
 */
@MainActor
final class ReviewActorCollector {
    private(set) var dismissers = [Int: String]()
    private var requestedPullRequests = Set<NSManagedObjectID>()

    /** Keeps the first login offered for a review. */
    func addDismisser(_ login: String, forReview reviewId: Int) {
        if dismissers[reviewId] == nil {
            dismissers[reviewId] = login
        }
    }

    /** Stores the first login offered for a pull request. */
    func setRequester(_ login: String, on pullRequest: PullRequest) {
        if requestedPullRequests.insert(pullRequest.objectID).inserted {
            pullRequest.reviewRequesterName = login
        }
    }
}

extension API {
    private static func handleRepoSync(for repo: Repo, result: DataResult) {
        switch result {
        case .cancelled, .ignored, .success:
            break // all good
        case .notFound:
            repo.inaccessible = true
            repo.postSyncAction = PostSyncAction.doNothing.rawValue
            for p in repo.pullRequests {
                p.postSyncAction = PostSyncAction.delete.rawValue
            }
            for i in repo.issues {
                i.postSyncAction = PostSyncAction.delete.rawValue
            }
        case .deleted:
            repo.postSyncAction = PostSyncAction.delete.rawValue
        case .failed:
            repo.apiServer.lastSyncSucceeded = false
        }
    }

    private static func fetchItems(for repos: [Repo], in moc: NSManagedObjectContext) async {
        for r in repos {
            for p in r.pullRequests where p.condition == ItemCondition.open.rawValue {
                p.postSyncAction = PostSyncAction.delete.rawValue
            }

            for i in r.issues where i.condition == ItemCondition.open.rawValue {
                i.postSyncAction = PostSyncAction.delete.rawValue
            }

            let apiServer = r.apiServer
            guard apiServer.lastSyncSucceeded else { continue }

            await withTaskGroup { group in
                if r.displayPolicyForPrs != RepoDisplayPolicy.hide.rawValue {
                    let repoFullName = r.fullName.orEmpty
                    group.addTask {
                        let result = await RestAccess.getPagedData(at: "/repos/\(repoFullName)/pulls", from: apiServer) { data, _ in
                            await PullRequest.syncPullRequests(from: data, in: r, moc: moc)
                            return false
                        }
                        await handleRepoSync(for: r, result: result)
                    }
                }

                if r.displayPolicyForIssues != RepoDisplayPolicy.hide.rawValue {
                    let repoFullName = r.fullName.orEmpty
                    group.addTask {
                        let result = await RestAccess.getPagedData(at: "/repos/\(repoFullName)/issues", from: apiServer) { data, _ in
                            await Issue.syncIssues(from: data, in: r, moc: moc)
                            return false
                        }
                        await handleRepoSync(for: r, result: result)
                    }
                }
            }
        }
    }

    /** Reads the review actors out of one repo's issue events. */
    @MainActor
    private struct ReviewActorScan {
        let apiServer: ApiServer
        let myTeamSlugs: Set<String>
        let prsByNumber: [Int: PullRequest]
        let collectDismissers: Bool
        let collectRequesters: Bool
        let collector: ReviewActorCollector

        /**
         Reads one issue event and keeps it when it names a review actor. A review request is applied at
         once, and only when it names me or one of my teams. Any other event is ignored.
         */
        func read(_ event: TypedJson.Entry, named name: String) {
            switch name {
            case "review_dismissed":
                guard collectDismissers,
                      let reviewId = event.potentialObject(named: "dismissed_review")?.potentialInt(named: "review_id"),
                      let actor = event.potentialObject(named: "actor")?.potentialString(named: "login") else {
                    return
                }
                collector.addDismisser(actor, forReview: reviewId)

            case "review_requested":
                guard collectRequesters,
                      let issueNumber = event.potentialObject(named: "issue")?.potentialInt(named: "number"),
                      let actor = event.potentialObject(named: "actor")?.potentialString(named: "login") else {
                    return
                }
                // An event carries a reviewer or a team, never both, so this chain is safe.
                if let login = event.potentialObject(named: "requested_reviewer")?.potentialString(named: "login") {
                    if apiServer.isMe(login), let pr = prsByNumber[issueNumber] {
                        collector.setRequester(actor, on: pr)
                    }
                } else if let slug = event.potentialObject(named: "requested_team")?.potentialString(named: "slug"),
                          myTeamSlugs.contains(slug),
                          let pr = prsByNumber[issueNumber] {
                    collector.setRequester(actor, on: pr)
                }

            default:
                break
            }
        }
    }

    private static func markExtraUpdatedItems(from repos: [Repo], settings: Settings.Cache) async -> ReviewActorCollector {
        let collector = ReviewActorCollector()
        let collectDismissers = settings.shouldSyncReviewDismissers
        let collectRequesters = settings.shouldSyncReviewRequesters
        let collectActors = collectDismissers || collectRequesters

        await withTaskGroup { group in
            for r in repos {
                let repoFullName = r.fullName.orEmpty
                let lastLocalEvent = r.lastScannedIssueEventId
                let isFirstEventSync = lastLocalEvent == 0
                r.lastScannedIssueEventId = 0
                group.addTask { @MainActor in
                    let apiServer = r.apiServer
                    // only the requester arm reads the teams and the pull requests, so the dismisser arm faults neither
                    let scan: ReviewActorScan? = if collectActors {
                        ReviewActorScan(apiServer: apiServer,
                                        myTeamSlugs: collectRequesters ? apiServer.myTeamSlugs : [],
                                        prsByNumber: collectRequesters ? Dictionary(r.pullRequests.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first }) : [:],
                                        collectDismissers: collectDismissers,
                                        collectRequesters: collectRequesters,
                                        collector: collector)
                    } else {
                        nil
                    }
                    let result = await RestAccess.getPagedData(at: "/repos/\(repoFullName)/issues/events", from: apiServer) { data, _ in
                        guard let data, !data.isEmpty else { return true }

                        if isFirstEventSync {
                            await Logging.shared.log("First event check for this repo. Let's ensure all items are marked as updated")
                            for i in r.pullRequests {
                                i.setToUpdatedIfIdle()
                            }
                            for i in r.issues {
                                i.setToUpdatedIfIdle()
                            }
                            if let scan {
                                for event in data {
                                    guard let eventName = event.potentialString(named: "event") else { continue }
                                    scan.read(event, named: eventName)
                                }
                            }
                            r.lastScannedIssueEventId = data.first!.potentialInt(named: "id") ?? 0
                            return true

                        } else {
                            var numbers = Set<Int>()
                            var foundLastEvent = false
                            for event in data {
                                if let eventId = event.potentialInt(named: "id"), let issue = event.potentialObject(named: "issue"), let issueNumber = issue.potentialInt(named: "number") {
                                    if r.lastScannedIssueEventId == 0 {
                                        r.lastScannedIssueEventId = eventId
                                    }
                                    if eventId == lastLocalEvent {
                                        foundLastEvent = true
                                        await Logging.shared.log("Parsed all repo issue events up to the one we already have")
                                        break // we're done
                                    }
                                    if let eventName = event.potentialString(named: "event") {
                                        scan?.read(event, named: eventName)
                                        numbers.insert(issueNumber)
                                    }
                                }
                            }
                            if r.lastScannedIssueEventId == 0 {
                                r.lastScannedIssueEventId = lastLocalEvent
                            }
                            if !numbers.isEmpty {
                                r.markItemsAsUpdated(with: numbers)
                            }
                            return foundLastEvent
                        }
                    }
                    switch result {
                    case .cancelled, .ignored, .success:
                        break
                    case .deleted, .failed, .notFound:
                        apiServer.lastSyncSucceeded = false
                    }
                }
            }
        }
        return collector
    }

    static func v3Sync(_ repos: [Repo], to moc: NSManagedObjectContext, settings: Settings.Cache) async {
        await fetchItems(for: repos, in: moc)
        let reposWithSomeItems = repos.filter { !$0.issues.isEmpty || !$0.pullRequests.isEmpty }
        let reviewActors = await markExtraUpdatedItems(from: reposWithSomeItems, settings: settings)
        let newOrUpdatedPrs = PullRequest.newOrUpdatedItems(in: moc, fromSuccessfulSyncOnly: true)
        let newOrUpdatedIssues = Issue.newOrUpdatedItems(in: moc, fromSuccessfulSyncOnly: true)

        await withTaskGroup { group in
            if Settings.showStatusItems {
                group.addTask {
                    await fetchStatusesForCurrentPullRequests(to: moc, settings: settings)
                }
            } else {
                for p in PullRequest.allItems(in: moc) {
                    p.lastStatusScan = nil
                    for status in p.statuses {
                        status.postSyncAction = PostSyncAction.delete.rawValue
                    }
                }
            }

            if Settings.notifyOnItemReactions {
                group.addTask { @MainActor in
                    let items = PullRequest.reactionCheckBatch(in: moc, settings: settings)
                    await fetchItemReactionsIfNeeded(for: items, to: moc)
                }

                group.addTask { @MainActor in
                    let items = Issue.reactionCheckBatch(in: moc, settings: settings)
                    await fetchItemReactionsIfNeeded(for: items, to: moc)
                }
            }

            if Settings.showLabels {
                group.addTask {
                    await fetchLabelsForCurrentPullRequests(for: newOrUpdatedPrs)
                }
                group.addTask {
                    await fetchLabelsForCurrentIssues(for: newOrUpdatedIssues)
                }
            } else {
                for l in PRLabel.allItems(in: moc) {
                    l.postSyncAction = PostSyncAction.delete.rawValue
                }
            }

            group.addTask {
                await checkPrClosures(in: moc)
            }

            group.addTask {
                await detectAssignedPullRequests(for: newOrUpdatedPrs)
            }

            if settings.shouldSyncReviewAssignments {
                group.addTask {
                    await fetchReviewAssignmentsForCurrentPullRequests(for: newOrUpdatedPrs, settings: settings)
                }
            }

            await withTaskGroup { commentGroup in
                if settings.shouldSyncReviews {
                    commentGroup.addTask {
                        await fetchReviewsForForCurrentPullRequests(to: moc, for: newOrUpdatedPrs)
                        await fetchCommentsForCurrentPullRequests(to: moc, for: newOrUpdatedPrs)
                    }
                } else {
                    for r in Review.allItems(in: moc) {
                        r.postSyncAction = PostSyncAction.delete.rawValue
                    }
                    commentGroup.addTask {
                        await fetchCommentsForCurrentPullRequests(to: moc, for: newOrUpdatedPrs)
                    }
                }

                commentGroup.addTask {
                    await fetchCommentsForCurrentIssues(to: moc, for: newOrUpdatedIssues)
                    await checkIssueClosures(in: moc)
                }
            }

            // v3 reviews are keyed on serverId, so the rows may not exist until the review fetch above has run
            let dismissers = reviewActors.dismissers
            for review in Review.reviews(with: Array(dismissers.keys), in: moc) {
                review.dismisserName = dismissers[review.serverId]
            }

            if Settings.notifyOnCommentReactions {
                group.addTask {
                    await fetchCommentReactionsIfNeeded(to: moc)
                }
            }
        }
    }

    private static func checkIssueClosures(in moc: NSManagedObjectContext) {
        let f = NSFetchRequest<Issue>(entityName: "Issue")
        f.predicate =
            NSCompoundPredicate(type: .and, subpredicates: [
                ItemCondition.closed.matchingPredicate,
                NSCompoundPredicate(type: .or, subpredicates: [
                    PostSyncAction.isUpdated.matchingPredicate,
                    PostSyncAction.delete.matchingPredicate
                ])
            ])
        f.returnsObjectsAsFaults = false
        f.includesSubentities = false
        let items = try! moc.fetch(f)
        for i in items.filter(\.shouldCheckForClosing) {
            i.stateChanged = ListableItem.StateChange.closed.rawValue
            i.postSyncAction = PostSyncAction.isUpdated.rawValue // let handleClosing() decide
        }
    }

    private static func fetchCommentReactionsIfNeeded(to moc: NSManagedObjectContext) async {
        let comments = PRComment.commentsThatNeedReactionsToBeRefreshed(in: moc)

        if comments.isEmpty {
            return
        }

        await withTaskGroup { group in
            for c in comments {
                for r in c.reactions {
                    r.postSyncAction = PostSyncAction.delete.rawValue
                }
                guard let reactionUrl = c.reactionsUrl else { continue }
                group.addTask { @MainActor in
                    let result = await RestAccess.getPagedData(at: reactionUrl, from: c.apiServer) { data, _ in
                        await Reaction.syncReactions(from: data, commentId: c.objectID, serverId: c.apiServer.objectID, moc: moc)
                        return false
                    }
                    switch result {
                    case .cancelled:
                        break
                    case .ignored, .success:
                        c.pendingReactionScan = false
                    case .deleted, .failed, .notFound:
                        c.apiServer.lastSyncSucceeded = false
                    }
                }
            }
        }
    }

    private static func fetchItemReactionsIfNeeded(for items: [some ListableItem], to moc: NSManagedObjectContext) async {
        if items.isEmpty {
            return
        }

        let now = Date()
        await withTaskGroup { group in
            for i in items {
                i.lastReactionScan = now
                for r in i.reactions {
                    r.postSyncAction = PostSyncAction.delete.rawValue
                }
                guard let reactionsUrl = i.reactionsUrl else {
                    continue
                }
                let oid = i.objectID
                let serverId = i.apiServer.objectID
                group.addTask { @MainActor in
                    let apiServer = i.apiServer
                    let result = await RestAccess.getPagedData(at: reactionsUrl, from: apiServer) { data, _ in
                        await Reaction.syncReactions(from: data, parentId: oid, serverId: serverId, moc: moc)
                        return false
                    }
                    switch result {
                    case .cancelled, .ignored, .success:
                        break
                    case .deleted, .failed, .notFound:
                        apiServer.lastSyncSucceeded = false
                    }
                }
            }
        }
    }

    private static func fetchCommentsForCurrentPullRequests(to moc: NSManagedObjectContext, for prs: [PullRequest]) async {
        if prs.isEmpty {
            return
        }

        for p in prs {
            for c in p.comments {
                c.postSyncAction = PostSyncAction.delete.rawValue
            }
        }

        @MainActor
        @Sendable func _fetchComments(issues: Bool) async {
            await withTaskGroup { group in
                for p in prs {
                    if let link = (issues ? p.commentsLink : p.reviewCommentLink) {
                        let apiServer = p.apiServer
                        group.addTask { @MainActor in
                            let result = await RestAccess.getPagedData(at: link, from: apiServer) { data, _ in
                                await PRComment.syncComments(from: data, parent: p, moc: moc, isCode: !issues)
                                return false
                            }
                            switch result {
                            case .cancelled, .ignored, .success:
                                break
                            case .deleted, .failed, .notFound:
                                apiServer.lastSyncSucceeded = false
                            }
                        }
                    }
                }
            }
        }

        await withTaskGroup { group in
            group.addTask {
                await _fetchComments(issues: true)
            }
            group.addTask {
                await _fetchComments(issues: false)
            }
        }
    }

    private static func fetchCommentsForCurrentIssues(to moc: NSManagedObjectContext, for issues: [Issue]) async {
        if issues.isEmpty {
            return
        }

        await withTaskGroup { group in
            for i in issues {
                for c in i.comments {
                    c.postSyncAction = PostSyncAction.delete.rawValue
                }

                if let link = i.commentsLink {
                    let apiServer = i.apiServer

                    group.addTask { @MainActor in
                        let result = await RestAccess.getPagedData(at: link, from: apiServer) { data, _ in
                            await PRComment.syncComments(from: data, parent: i, moc: moc, isCode: false)
                            return false
                        }
                        switch result {
                        case .cancelled, .ignored, .success:
                            break
                        case .deleted, .failed, .notFound:
                            apiServer.lastSyncSucceeded = false
                        }
                    }
                }
            }
        }
    }

    private static func fetchReviewsForForCurrentPullRequests(to moc: NSManagedObjectContext, for prs: [PullRequest]) async {
        if prs.isEmpty {
            return
        }

        await withTaskGroup { group in
            for p in prs {
                for l in p.reviews {
                    l.postSyncAction = PostSyncAction.delete.rawValue
                }
                let repoFullName = p.repo.fullName.orEmpty
                group.addTask { @MainActor in
                    let apiServer = p.apiServer
                    let result = await RestAccess.getPagedData(at: "/repos/\(repoFullName)/pulls/\(p.number)/reviews", from: apiServer) { data, _ in
                        await Review.syncReviews(from: data, withParent: p, moc: moc)
                        return false
                    }
                    switch result {
                    case .cancelled, .ignored, .success:
                        break
                    case .deleted, .failed, .notFound:
                        apiServer.lastSyncSucceeded = false
                    }
                }
            }
        }
    }

    private static func investigatePrClosure(for pullRequest: PullRequest) async {
        let prTitle = pullRequest.title.orEmpty
        await Logging.shared.log("Checking closed PR to see if it was merged: \(prTitle)")

        let repoFullName = pullRequest.repo.fullName.orEmpty
        let path = "/repos/\(repoFullName)/pulls/\(pullRequest.number)"

        do {
            let (data, _, result) = try await RestAccess.getData(in: path, from: pullRequest.apiServer)
            switch result {
            case .success:
                if let data {
                    if let mergeInfo = data.potentialObject(named: "merged_by"), let mergeUserId = mergeInfo.potentialString(named: "node_id") {
                        pullRequest.mergedByNodeId = mergeUserId
                        pullRequest.stateChanged = ListableItem.StateChange.merged.rawValue
                        pullRequest.postSyncAction = PostSyncAction.isUpdated.rawValue // let handleMerging() decide

                    } else {
                        pullRequest.stateChanged = ListableItem.StateChange.closed.rawValue
                        pullRequest.postSyncAction = PostSyncAction.isUpdated.rawValue // let handleClosing() decide
                    }
                }
            case .deleted, .notFound:
                pullRequest.stateChanged = ListableItem.StateChange.closed.rawValue
                pullRequest.postSyncAction = PostSyncAction.isUpdated.rawValue // let handleClosing() decide
            case .cancelled, .failed, .ignored:
                pullRequest.postSyncAction = PostSyncAction.doNothing.rawValue // keep since we don't know what's going on here
                pullRequest.apiServer.lastSyncSucceeded = false
            }
        } catch {
            pullRequest.postSyncAction = PostSyncAction.doNothing.rawValue // keep since we don't know what's going on here
            pullRequest.apiServer.lastSyncSucceeded = false
        }
    }

    private static func checkPrClosures(in moc: NSManagedObjectContext) async {
        let f = NSFetchRequest<PullRequest>(entityName: "PullRequest")
        f.predicate = NSCompoundPredicate(type: .and, subpredicates: [PostSyncAction.delete.matchingPredicate, ItemCondition.open.matchingPredicate])
        f.returnsObjectsAsFaults = false
        f.includesSubentities = false

        let prsToCheck = try! moc.fetch(f).filter(\.shouldCheckForClosing)

        await withTaskGroup { group in
            for r in prsToCheck {
                group.addTask {
                    await investigatePrClosure(for: r)
                }
            }
        }
    }

    private static func fetchReviewAssignmentsForCurrentPullRequests(for prs: [PullRequest], settings: Settings.Cache) async {
        await withThrowingTaskGroup { group in
            for p in prs {
                group.addTask { @MainActor in
                    let repoFullName = p.repo.fullName.orEmpty
                    let (data, _) = try await RestAccess.getRawData(at: "/repos/\(repoFullName)/pulls/\(p.number)/requested_reviewers", from: p.apiServer)
                    var reviewUsers = Set<String>()
                    var reviewTeams = Set<String>()

                    if let userList = data?.potentialArray {
                        // Legacy API results
                        for userName in userList.compactMap({ $0.potentialString(named: "login") }) {
                            reviewUsers.insert(userName)
                        }
                        p.checkAndStoreReviewAssignments(reviewUsers, reviewTeams, settings: settings)

                    } else if let data, let userList = data.potentialArray(named: "users"), let teamList = data.potentialArray(named: "teams") {
                        // New API results
                        for userName in userList.compactMap({ $0.potentialString(named: "login") }) {
                            reviewUsers.insert(userName)
                        }
                        for teamName in teamList.compactMap({ $0.potentialString(named: "slug") }) {
                            reviewTeams.insert(teamName)
                        }
                        p.checkAndStoreReviewAssignments(reviewUsers, reviewTeams, settings: settings)

                    } else {
                        p.apiServer.lastSyncSucceeded = false
                    }
                }
            }
        }
    }

    private static func fetchLabelsForCurrentPullRequests(for prs: [PullRequest]) async {
        if prs.isEmpty {
            return
        }

        await withTaskGroup { group in
            for p in prs {
                for l in p.labels {
                    l.postSyncAction = PostSyncAction.delete.rawValue
                }

                guard let link = p.labelsLink else {
                    continue
                }

                group.addTask { @MainActor in
                    let apiServer = p.apiServer
                    let result = await RestAccess.getPagedData(at: link, from: apiServer) { data, _ in
                        PRLabel.syncLabels(from: data, withParent: p)
                        return false
                    }
                    switch result {
                    case .cancelled, .deleted, .ignored, .notFound, .success:
                        break
                    case .failed:
                        apiServer.lastSyncSucceeded = false
                    }
                }
            }
        }
    }

    private static func fetchLabelsForCurrentIssues(for issues: [Issue]) async {
        if issues.isEmpty {
            return
        }

        await withTaskGroup { group in
            for i in issues {
                for l in i.labels {
                    l.postSyncAction = PostSyncAction.delete.rawValue
                }

                guard let link = i.labelsLink else {
                    continue
                }

                group.addTask { @MainActor in
                    let apiServer = i.apiServer
                    let result = await RestAccess.getPagedData(at: link, from: apiServer) { data, _ in
                        PRLabel.syncLabels(from: data, withParent: i)
                        return false
                    }
                    switch result {
                    case .cancelled, .deleted, .ignored, .notFound, .success:
                        break
                    case .failed:
                        apiServer.lastSyncSucceeded = false
                    }
                }
            }
        }
    }

    private static func fetchStatusesForCurrentPullRequests(to moc: NSManagedObjectContext, settings: Settings.Cache) async {
        let prs = PullRequest.statusCheckBatch(in: moc, settings: settings)
        if prs.isEmpty {
            return
        }

        let now = Date()
        await withTaskGroup { group in
            for p in prs {
                for s in p.statuses {
                    s.postSyncAction = PostSyncAction.delete.rawValue
                }

                let apiServer = p.apiServer

                if let statusLink = p.statusesLink {
                    group.addTask { @MainActor in
                        let result = await RestAccess.getPagedData(at: statusLink, from: apiServer) { data, _ in
                            await PRStatus.syncStatuses(from: data, pullRequest: p, moc: moc)
                            return false
                        }
                        switch result {
                        case .cancelled, .ignored:
                            break
                        case .deleted, .notFound, .success:
                            p.lastStatusScan = now
                        case .failed:
                            apiServer.lastSyncSucceeded = false
                        }
                    }
                } else {
                    p.lastStatusScan = now
                }
            }
        }
    }

    private static func detectAssignedPullRequests(for prs: [PullRequest]) async {
        await withTaskGroup { group in
            for p in prs {
                let apiServer = p.apiServer
                if let issueLink = p.issueUrl {
                    group.addTask { @MainActor in
                        do {
                            let (data, _, _) = try await RestAccess.getData(in: issueLink, from: apiServer)
                            if let data {
                                p.processAssignmentStatus(from: data, idField: "node_id")
                            }
                        } catch {
                            apiServer.lastSyncSucceeded = false
                        }
                    }
                }
            }
        }
    }
}
