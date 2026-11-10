import Foundation
import UserNotifications

/**
 Makes the sound that the user selected available to the notification centre.

 `UNNotificationSound` finds a file only in the `Library/Sounds` folder of the app data container, in
 the `Library/Sounds` folder of an app group container, or in the app bundle. The app is not sandboxed,
 so its data container is the home folder. The sounds that the preferences list live in
 `/System/Library/Sounds`, which is none of those, so the selected file is copied into the user's
 `~/Library/Sounds` before a notification asks for it.

 Each copy is named with a `Trailer ` prefix, so it cannot shadow a system sound or be confused with a
 file that the user put in that folder. A copy is replaced when the system file changes, and copies that
 no setting uses are removed, because other apps list that folder in their sound pickers too.
 */
enum NotificationSoundLibrary {
    /** The folder that holds the sounds which macOS supplies. */
    static let systemSoundsFolder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /** The folder that the notification centre searches, or `nil` if the user Library folder is not available. */
    static let destinationFolder = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("Sounds", isDirectory: true)

    /** Starts the name of every copy, so that only Trailer's own files are ever replaced or removed. */
    private static let copyPrefix = "Trailer "

    /** The file attributes that tell whether a copy still matches its system file. */
    private static let comparedKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]

    /**
     Copies the named system sound into the destination folder, unless an identical copy is there already.

     Returns the name of the copy for `UNNotificationSound(named:)`, or `nil` if the sound is not
     available, so that the caller can use the default sound.
     */
    static func install(_ name: String) -> UNNotificationSoundName? {
        // The name comes from a folder listing or from UserDefaults, so it must not walk the path.
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else {
            Task { await Logging.shared.log("Notification sound '\(name)' has an unsafe name, not installing") }
            return nil
        }
        guard let destinationFolder else {
            Task { await Logging.shared.log("Notification sound '\(name)' not installed, no user Library folder") }
            return nil
        }

        let source = systemSoundsFolder.appendingPathComponent(name)
        guard let sourceValues = try? source.resourceValues(forKeys: comparedKeys) else {
            Task { await Logging.shared.log("Notification sound '\(name)' not found in \(source.path)") }
            return nil
        }

        let copyName = copyPrefix + name
        let destination = destinationFolder.appendingPathComponent(copyName)
        let copyValues = try? destination.resourceValues(forKeys: comparedKeys)
        if let copyValues,
           copyValues.fileSize == sourceValues.fileSize,
           copyValues.contentModificationDate == sourceValues.contentModificationDate {
            return UNNotificationSoundName(copyName)
        }

        let fileManager = FileManager.default
        do {
            if copyValues != nil {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            // Match the system file's date, so the next call can tell that the copy is current.
            if let date = sourceValues.contentModificationDate {
                try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
            }
            return UNNotificationSoundName(copyName)
        } catch {
            Task { await Logging.shared.log("Notification sound '\(name)' could not be copied: \(error.localizedDescription)") }
            return nil
        }
    }

    /** Deletes Trailer's copies of every sound whose system name is not in `names`. Other files are left alone. */
    static func removeCopies(except names: Set<String>) {
        guard let destinationFolder else { return }

        let fileManager = FileManager.default
        let kept = Set(names.map { copyPrefix + $0 })
        let contents = (try? fileManager.contentsOfDirectory(at: destinationFolder,
                                                             includingPropertiesForKeys: nil,
                                                             options: .skipsHiddenFiles)) ?? []
        let unused = contents.filter {
            $0.lastPathComponent.hasPrefix(copyPrefix) && !kept.contains($0.lastPathComponent)
        }

        for url in unused {
            do {
                try fileManager.removeItem(at: url)
                Task { await Logging.shared.log("Removed unused notification sound '\(url.lastPathComponent)'") }
            } catch {
                Task { await Logging.shared.log("Could not remove notification sound '\(url.lastPathComponent)': \(error.localizedDescription)") }
            }
        }
    }
}
