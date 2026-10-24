import SwiftUI

@main
struct HelloHost: App {
    var body: some Scene {
        WindowGroup("MacdroidBridge — FSKit M0") {
            VStack(alignment: .leading, spacing: 16) {
                Text("MacdroidBridge").font(.title)
                Text("Read-only FSKit Hello World")
                Text("Documents/hello.txt\nREADME.txt").font(.system(.body, design: .monospaced))
                Text("This host contains the FSKit extension. Signing, extension enablement and an explicitly authorized mount test are required before Finder visibility can be verified.")
                Text("No USB or MTP access. This app does not mount volumes.").foregroundStyle(.secondary)
            }.padding(28).frame(width: 480)
        }
    }
}
