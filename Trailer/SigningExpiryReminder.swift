import Foundation
import Security
@preconcurrency import UserNotifications

/**
 The moment this build's signing must be renewed by, and what expires then. An expired provisioning profile
 stops the app launching; an expired certificate stops Xcode signing new builds with it.
 */
struct SigningDeadline: Equatable {
    enum Source {
        case certificate, provisioningProfile

        var title: String {
            switch self {
            case .certificate: "signing certificate"
            case .provisioningProfile: "provisioning profile"
            }
        }
    }

    let date: Date
    let source: Source

    /** The deadline of the running app, or `nil` if its signature carries no expiry, as with an ad-hoc signature. */
    static func current() -> SigningDeadline? {
        earliest(certificateExpiry: leafCertificateExpiry(),
                 profileExpiry: profileExpiry(at: Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")))
    }

    /** The earlier of the two expiry dates, labelled with what expires. */
    static func earliest(certificateExpiry: Date?, profileExpiry: Date?) -> SigningDeadline? {
        [certificateExpiry.map { SigningDeadline(date: $0, source: .certificate) },
         profileExpiry.map { SigningDeadline(date: $0, source: .provisioningProfile) }]
            .compactMap(\.self)
            .min { $0.date < $1.date }
    }

    /** The "not after" date of the certificate that signed the running app. */
    private static func leafCertificateExpiry() -> Date? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let notAfter = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = notAfter[kSecPropertyKeyValue as String] as? Double
        else { return nil }

        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /** The `ExpirationDate` of the provisioning profile at `url`, or `nil` if there is no readable profile. */
    private static func profileExpiry(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }

        let updated = data.withUnsafeBytes { bytes in
            bytes.baseAddress.map { CMSDecoderUpdateMessage(decoder, $0, bytes.count) } ?? errSecParam
        }
        var content: CFData?
        guard updated == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content,
              let plist = try? PropertyListSerialization.propertyList(from: content as Data, format: nil) as? [String: Any]
        else { return nil }

        return plist["ExpirationDate"] as? Date
    }
}

/**
 Keeps one pending notification that warns a week before the app's signing expires, so there is time to
 renew it in Xcode first.

 Each call replaces the earlier request, so launches do not stack reminders.
 */
@MainActor
enum SigningExpiryReminder {
    private static let requestIdentifier = "SigningExpiryReminder"
    private static let leadTime: TimeInterval = 7 * 24 * 60 * 60
    private static var settingsObserver: NSObjectProtocol?

    /** Schedules the reminder, and schedules it again whenever its notification settings change. */
    static func start() {
        if settingsObserver == nil {
            settingsObserver = NotificationCenter.default.addObserver(forName: .notificationSettingsChanged, object: nil, queue: .main) { notification in
                guard notification.object as? NotificationType == .signingExpiry else { return }
                Task { @MainActor in
                    schedule()
                }
            }
        }
        schedule()
    }

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])

        guard Settings.notificationEnabled(for: .signingExpiry) else {
            Task { await Logging.shared.log("Signing expiry reminder is turned off") }
            return
        }
        guard let deadline = SigningDeadline.current() else {
            Task { await Logging.shared.log("No signing expiry found, so no reminder is scheduled") }
            return
        }

        let fireDate = deadline.date.addingTimeInterval(-leadTime)
        // A nil trigger delivers at once, which covers a deadline that is already less than a week away.
        let trigger = fireDate > .now
            ? UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                                            repeats: false)
            : nil
        let request = UNNotificationRequest(identifier: requestIdentifier, content: content(for: deadline), trigger: trigger)

        Task {
            do {
                try await center.add(request)
                await Logging.shared.log("The \(deadline.source.title) expires \(deadline.date), reminder set for \(trigger == nil ? "now" : "\(fireDate)")")
            } catch {
                await Logging.shared.log("Could not schedule the signing expiry reminder: \(error.localizedDescription)")
            }
        }
    }

    private static func content(for deadline: SigningDeadline) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let expired = deadline.date <= .now
        content.title = expired
            ? "Trailer's \(deadline.source.title) has expired"
            : "Trailer's \(deadline.source.title) expires soon"
        let when = deadline.date.formatted(date: .long, time: .shortened)
        content.body = "\(expired ? "It expired" : "It expires") on \(when). Renew it in Xcode › Settings › Accounts, then rebuild the app."
        content.sound = Settings.notificationSound(for: .signingExpiry).prepared()
        return content
    }
}
