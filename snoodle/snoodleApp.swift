//
//  snoodleApp.swift
//  snoodle
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseMessaging
import UserNotifications

@main
struct snoodleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()

        // On fresh install, UserDefaults are wiped but Firebase Keychain persists.
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            try? Auth.auth().signOut()
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }

        _ = SnoodleAuthManager.shared

        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self

        // Request permission after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                guard granted else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                    // Start watchdog to catch APNs token intercepted by Firebase swizzling
                    self.startAPNsWatchdog()
                }
            }
        }

        return true
    }

    // Watchdog: Firebase swizzling intercepts the APNs token but doesn't forward it
    // to our delegate. Poll for it, then force-reassign to kick Firebase out of APA91b mode.
    private func startAPNsWatchdog() {
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            attempts += 1
            if let apnsToken = Messaging.messaging().apnsToken {
                timer.invalidate()
                // Re-assign to trigger Firebase's internal association loop
                Messaging.messaging().apnsToken = apnsToken
                self.refreshRealFCMToken()
            } else if attempts > 20 {
                print("⚠️ Watchdog timed out — APNs token never arrived")
                timer.invalidate()
            }
        }
    }

    private func refreshRealFCMToken() {
        Messaging.messaging().token { token, error in
            if let error = error {
                print("❌ FCM token error: \(error.localizedDescription)")
                return
            }
            guard let token = token else { return }

            if token.contains("APA91b") {
                Messaging.messaging().deleteToken { error in
                    if let error = error {
                        print("❌ deleteToken error: \(error.localizedDescription)")
                        return
                    }
                    Messaging.messaging().token { freshToken, _ in
                        if let finalToken = freshToken {
                            NotificationManager.shared.saveFCMToken(finalToken)
                        }
                    }
                }
            } else {
                NotificationManager.shared.saveFCMToken(token)
            }
        }
    }

    // Called by Firebase swizzle — may or may not fire depending on SwiftUI lifecycle
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ APNs registration FAILED: \(error.localizedDescription)")
    }

    // FCM token refreshed by Firebase
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        if token.contains("APA91b") {
            return
        }
        NotificationManager.shared.saveFCMToken(token)
    }

    // Foreground notification
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    // Notification tapped
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        NotificationManager.shared.handleNotificationTap(userInfo: userInfo)
        completionHandler()
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}


