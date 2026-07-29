import AppKit
import CoreGraphics

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "list" {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in info where (w["kCGWindowOwnerName"] as? String)?.contains("Claude Island") == true {
        let b = w["kCGWindowBounds"] as! [String: Any]
        print("bounds x=\(b["X"]!) y=\(b["Y"]!) w=\(b["Width"]!) h=\(b["Height"]!) layer=\(w["kCGWindowLayer"]!)")
    }
} else if args.count >= 4 && args[1] == "click" {
    let pt = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    print("clicked \(pt)")
} else if args.count >= 4 && args[1] == "move" {
    let pt = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    print("moved \(pt)")
}
