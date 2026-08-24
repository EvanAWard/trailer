import Foundation

/**
 Makes the sound that the user selected available to the notification centre.

 `UNNotificationSound` finds a file only in the `Library/Sounds` folder of the app data container, in
 the `Library/Sounds` folder of an app group container, or in the app bundle. The sounds that the
 preferences list live in `/System/Library/Sounds`, which is none of those, so the selected file is
 copied into the app group container before a notification asks for it.
 */
enum NotificationSoundLibrary {
    /** The folder that holds the sounds which macOS supplies. */
    static let systemSoundsFolder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /** The folder that the notification centre searches, or `nil` if the container is not available. */
    static let destinationFolder = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Sounds", isDirectory: true)

    /**
     Copies the named sound into the destination folder, unless it is there already.

     Returns `false` if the sound is not available, so that the caller can use the default sound.
     */
    static func install(_ name: String) -> Bool {
        // The name comes from a folder listing or from UserDefaults, so it must not walk the path.
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else {
            Task { await Logging.shared.log("Notification sound '\(name)' has an unsafe name, not installing") }
            return false
        }
        guard let destinationFolder else {
            Task { await Logging.shared.log("Notification sound '\(name)' not installed, no app group container") }
            return false
        }

        let fileManager = FileManager.default
        let destination = destinationFolder.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            return true
        }

        let source = systemSoundsFolder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: source.path) else {
            Task { await Logging.shared.log("Notification sound '\(name)' not found in \(source.path)") }
            return false
        }

        do {
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch {
            Task { await Logging.shared.log("Notification sound '\(name)' could not be copied: \(error.localizedDescription)") }
            return false
        }
    }
}
