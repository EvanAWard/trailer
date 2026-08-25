import Foundation

/**
 Decides whether the changed files of a pull request match the user's path patterns.

 Every member is pure and takes its data as a parameter, so this type reaches none of Core Data,
 the settings suite or the network. `PullRequest` reads its stored values and calls in.
 */
enum PathFilter {
    /**
     One user pattern, normalised once so that matching allocates nothing.
     */
    enum Pattern {
        private static let wildcards: Set<Character> = ["*", "?"]
        private static let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/"))

        case glob(String)
        case components(prefix: String, prefixWithSlash: String)

        /**
         Prepares one pattern, or gives nil when nothing is left to match against.

         A changed file path arrives relative to the root of the repository, so a leading separator
         would match nothing and comes off in the same pass as the surrounding whitespace.
         */
        init?(_ text: String) {
            let normalised = text.trimmingCharacters(in: Pattern.trimmed).comparableForm
            if normalised.isEmpty {
                return nil
            }

            if normalised.contains(where: { Pattern.wildcards.contains($0) }) {
                // fnmatch reads these as syntax, but the help text offers only * and ?
                self = .glob(normalised
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\["))
            } else {
                self = .components(prefix: normalised, prefixWithSlash: normalised + "/")
            }
        }

        /**
         Reports whether one changed file path matches this pattern. Both sides arrive in
         `comparableForm`, so the comparison ignores case and diacritics as every other filter list
         in the app does.

         A pattern that holds a wildcard is a glob. `FNM_PATHNAME` is deliberately not set, so a
         wildcard also crosses a directory separator and `*.md` finds a file at any depth. A pattern
         with no wildcard names whole path components instead, so `docs` reaches `docs/a.md` but
         never `documentation/a.md`.
         */
        func matches(comparablePath: String) -> Bool {
            switch self {
            case let .glob(glob):
                fnmatch(glob, comparablePath, FNM_CASEFOLD) == 0
            case let .components(prefix, prefixWithSlash):
                comparablePath == prefix || comparablePath.hasPrefix(prefixWithSlash)
            }
        }
    }

    /**
     The patterns that matching uses, which is where a blank entry is dropped.
     */
    static func patterns(from list: [String]) -> [Pattern] {
        list.compactMap(Pattern.init)
    }

    /**
     Reports whether one of these changed paths matches one of these patterns.
     */
    static func matchesAny(changedPaths: [String], patterns: [Pattern]) -> Bool {
        guard !patterns.isEmpty else { return false }
        return changedPaths.contains { path in
            let comparable = path.comparableForm
            return patterns.contains { $0.matches(comparablePath: comparable) }
        }
    }

    private static let separator = "\n"

    /**
     Joins a list of changed paths for storage in one attribute. An empty list gives an empty
     string, never nil, because only nil means that the sync never fetched the paths.

     A path which holds the separator is dropped. Git allows a newline in a path, and a stored one
     would split into two false entries when it is decoded.
     */
    static func encode(_ paths: [String]) -> String {
        paths.filter { !$0.contains(separator) }.joined(separator: separator)
    }

    /**
     Splits a stored value back into a list of changed paths.
     */
    static func decode(_ stored: String?) -> [String] {
        guard let stored, !stored.isEmpty else { return [] }
        return stored.components(separatedBy: separator)
    }
}
