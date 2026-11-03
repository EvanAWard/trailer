import CoreData
import TrailerJson

final class Team: DataItem {
    @NSManaged var slug: String?
    @NSManaged var organisationLogin: String?
    @NSManaged var calculatedReferral: String?

    override static var typeName: String {
        "Team"
    }

    static func team(with slug: String, in moc: NSManagedObjectContext) -> Team? {
        let f = NSFetchRequest<Team>(entityName: "Team")
        f.fetchLimit = 1
        f.returnsObjectsAsFaults = false
        f.includesSubentities = false
        f.predicate = NSPredicate(format: "slug == %@", slug)
        return try? moc.fetch(f).first
    }

    /**
     Turns ignored-team entries into the form that `isIgnored(by:)` checks: trimmed, lowercased, and
     without a leading `@`. Blank entries are dropped.
     */
    static func normalizedIgnoreEntries(_ entries: [String]) -> Set<String> {
        Set(entries.compactMap { entry in
            var normalized = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix("@") {
                normalized.removeFirst()
            }
            normalized = normalized.lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }

    /** Whether one of the normalised entries names this team, either by slug alone or as `org/slug`. */
    func isIgnored(by entries: Set<String>) -> Bool {
        guard !entries.isEmpty, let slug = slug?.lowercased(), !slug.isEmpty else {
            return false
        }
        if entries.contains(slug) {
            return true
        }
        guard let org = organisationLogin?.lowercased(), !org.isEmpty else {
            return false
        }
        return entries.contains("\(org)/\(slug)")
    }

    static func syncTeams(from data: [TypedJson.Entry]?, serverId: NSManagedObjectID, moc: NSManagedObjectContext) async {
        await v3items(with: data, type: Team.self, serverId: serverId, moc: moc) { item, info, _, _ in
            let slug = info.potentialString(named: "slug").orEmpty
            let org = (info.potentialObject(named: "organization")?.potentialString(named: "login")).orEmpty
            item.slug = slug
            item.organisationLogin = org
            if slug.isEmpty || org.isEmpty {
                item.calculatedReferral = nil
            } else {
                item.calculatedReferral = "@\(org)/\(slug)"
            }
            item.postSyncAction = PostSyncAction.doNothing.rawValue
        }
    }
}
