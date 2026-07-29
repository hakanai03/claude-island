import Foundation
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: dnpost <command>"); exit(1) }
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.claudeisland.uitest"),
    object: args[1],
    userInfo: nil,
    deliverImmediately: true
)
print("posted: \(args[1])")
