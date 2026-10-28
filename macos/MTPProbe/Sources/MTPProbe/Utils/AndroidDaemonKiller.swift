import Foundation
import AppKit

public struct AndroidDaemonKiller {
    
    /// Terminates known conflicting daemons like "Android File Transfer Agent"
    /// which aggressively claim MTP interfaces and prevent our probe from working.
    public static func terminateConflictingDaemons() {
        print("Checking for conflicting daemons...")
        
        let bundleIDs = [
            "com.google.android.mtpagent",
            "com.google.android.mtpviewer"
        ]
        
        // Attempt to kill via NSWorkspace if running as an app
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            if let bundleID = app.bundleIdentifier, bundleIDs.contains(bundleID) {
                print("Terminating conflicting daemon (by BundleID): \(app.localizedName ?? bundleID)")
                app.forceTerminate()
            } else if app.localizedName == "Android File Transfer Agent" || app.localizedName == "Android File Transfer" {
                print("Terminating conflicting app (by Name): \(app.localizedName ?? "Unknown")")
                app.forceTerminate()
            }
        }
        
        // Fallback: use killall via shell for the agent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "Android File Transfer Agent"]
        process.standardError = nil // Ignore errors if not found
        process.standardOutput = nil
        try? process.run()
        process.waitUntilExit()
        
        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process2.arguments = ["-9", "Android File Transfer"]
        process2.standardError = nil
        process2.standardOutput = nil
        try? process2.run()
        process2.waitUntilExit()
    }
}
