//
//  UserPresence.swift
//  SoftU2F
//
//  Created by Benjamin P Toews on 1/27/17.
//

import Foundation

class UserPresence: NSObject {
    enum Notification {
        case Register(facet: String?)
        case Authenticate(facet: String?)
    }

    typealias Callback = (_ success: Bool) -> Void

    static var skip = false

    // Hacks to avoid a race between reads/writes to current.
    static let mtx = Mutex()
    static var _current: UserPresence?
    static var current: UserPresence? {
        get {
            mtx.lock()
            defer { mtx.unlock() }
            return _current
        }

        set(newValue) {
            mtx.lock()
            defer { mtx.unlock() }
            _current = newValue
        }
    }

    // Display a notification, wait for the user to click it, and call the callback with `true`.
    // Calls callback with `false` if another test is done while we're waiting for this one.
    static func test(_ _type: Notification, skip skipOnce: Bool = false, with callback: @escaping Callback) {
        if skip || skipOnce {
            callback(true)
        } else {
            // Fail any outstanding test.
            current?.complete(false)

            // Backup previous delegate to restore on completion.
            let delegateWas = NSUserNotificationCenter.default.delegate

            let up = UserPresence { success in
                NSUserNotificationCenter.default.delegate = delegateWas
                callback(success)
            }

            current = up
            NSUserNotificationCenter.default.delegate = up
            up.test(_type)
        }
    }

    let callback: Callback
    var notification: NSUserNotification?
    var timer: Timer?
    var timerStart: Date?

    // Give up after 10 seconds.
    var timedOut: Bool {
        guard let ts = timerStart else { return false }
        return Date().timeIntervalSince(ts) > 10
    }

    // Helper for accessing user notification center singleton.
    var center: NSUserNotificationCenter { return NSUserNotificationCenter.default }

    init(with cb: @escaping Callback) {
        callback = cb
        super.init()
    }

    // Send a notification popup to the user.
    func test(_ _type: Notification) {
        sendNotification(_type)
    }

    // Send a notification popup to the user.
    func sendNotification(_ _type: Notification) {
        let n = NSUserNotification()
        n.title = "Security Key Request"
        n.actionButtonTitle = "Approve"
        n.otherButtonTitle = "Reject"

        switch _type {
        case let .Register(facet):
            n.informativeText = "Register with " + (facet ?? "site")
        case let .Authenticate(facet):
            n.informativeText = "Authenticate with " + (facet ?? "site")
        }

        NSUserNotificationCenter.default.deliver(n)

        notification = n
    }

    // Call the callback closure with our result and reset everything.
    func complete(_ result: Bool) {
        clearTimer()
        removeNotification()
        callback(result)
        UserPresence.current = nil
    }

    // Stop showing the notification.
    func removeNotification() {
        guard let n = notification else { return }
        center.removeDeliveredNotification(n)
    }

    // Install timer to check if user has dismissed notification.
    func installTimer() {
        timerStart = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let n = self.notification else { return }

            if self.timedOut {
                // It's taken too long.
                self.complete(false)
            } else if let _ = self.center.deliveredNotifications.index(of: n) {
                // User still viewing.
            } else {
                // User dismissed.
                self.complete(false)
            }
        }
    }

    // Stop the timer.
    func clearTimer() {
        guard let t = timer else { return }
        t.invalidate()
    }
}

extension UserPresence: NSUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: NSUserNotificationCenter, didDeliver notification: NSUserNotification) {
        if #available(OSX 10.13, *) {
          // notification.isPresented is always false on the latest 10.13 beta.
          installTimer()
        } else {
          if notification.isPresented {
            // Alert is showing to user. Watch to see if it's dismissed.
            installTimer()
          } else {
            // Alert wasn't shown to user. Fail.
            complete(false)
          }
        }
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        switch notification.activationType {
        case .actionButtonClicked:
            // User clicked "Accept".
            complete(true)
        default:
            // User did something else.
            complete(false)
        }
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        // Present notification even if we're in foreground.
        return true
    }
}
