import Foundation
import ServiceManagement

let svc = SMAppService.agent(plistName: "com.example.localllmchat.spike.gateway.plist")
let cmd = CommandLine.arguments.dropFirst().first ?? "status"
do {
    switch cmd {
    case "register": try svc.register()
    case "unregister": try svc.unregister()
    default: break
    }
} catch { print("error: \(error)") }
print("status: \(svc.status.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
