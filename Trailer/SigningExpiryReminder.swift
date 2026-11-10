import Foundation
import Security
@preconcurrency import UserNotifications

/**
 Warns a week before the certificate that signed the running app expires, so there is time to renew it in
 Xcode first. An expired certificate stops Xcode signing new builds with it.

 The reminder has its own settings, which stay on this Mac. Each certificate is announced once: when the
 week has already begun, a later launch or setting change does not post the reminder again.
 */
@MainActor
enum SigningExpiryReminder {
    private static let requestIdentifier = "SigningExpiryReminder"
    private static let leadTime: TimeInterval = 7 * 24 * 60 * 60

    /** The "not after" date of the certificate that signed the running app, or `nil` if the signature has none, as with an ad-hoc signature. */
    private static let certificateExpiry: Date? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }

        return SecCertificateCopyNotValidAfterDate(leaf) as Date?
    }()

    static var isEnabled: Bool {
        get { Settings.signingExpiryReminderEnabled }
        set {
            Settings.signingExpiryReminderEnabled = newValue
            schedule()
        }
    }

    static var sound: NotificationSound {
        get { NotificationSound(storedValue: Settings.signingExpiryReminderSound) }
        set {
            Settings.signingExpiryReminderSound = newValue.storedValue
            schedule()
        }
    }

    /** Replaces the pending reminder with one that matches the current settings. A fixed identifier keeps it to one. */
    static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])

        guard isEnabled, let expiry = certificateExpiry else {
            center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
            Settings.signingExpiryReminderSetFor = nil
            let reason = isEnabled ? "no signing certificate expiry was found" : "it is turned off"
            Task { await Logging.shared.log("No signing expiry reminder is scheduled, because \(reason)") }
            return
        }

        let fireDate = expiry.addingTimeInterval(-leadTime)
        let trigger: UNNotificationTrigger?
        if fireDate > .now {
            // A reminder that was delivered already can only be about an earlier certificate.
            center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSinceNow, repeats: false)
        } else if Settings.signingExpiryReminderSetFor == expiry {
            Task { await Logging.shared.log("The signing certificate expires \(expiry), and the reminder was posted already") }
            return
        } else {
            // A nil trigger delivers at once.
            trigger = nil
        }
        let request = UNNotificationRequest(identifier: requestIdentifier, content: content(for: expiry), trigger: trigger)

        Task {
            do {
                // The launch asks for authorization too, but without waiting, so a first launch could add the request too early.
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                    await Logging.shared.log("Notifications are not allowed, so no signing expiry reminder is scheduled")
                    return
                }
                try await center.add(request)
                Settings.signingExpiryReminderSetFor = expiry
                await Logging.shared.log("The signing certificate expires \(expiry), reminder set for \(trigger == nil ? "now" : "\(fireDate)")")
            } catch {
                await Logging.shared.log("Could not schedule the signing expiry reminder: \(error.localizedDescription)")
            }
        }
    }

    private static func content(for expiry: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let expired = expiry <= .now
        content.title = expired
            ? "Trailer's signing certificate has expired"
            : "Trailer's signing certificate expires soon"
        let when = expiry.formatted(date: .long, time: .shortened)
        content.body = "\(expired ? "It expired" : "It expires") on \(when). Renew it in Xcode › Settings › Accounts, then rebuild the app."
        content.sound = sound.prepared()
        return content
    }
}
