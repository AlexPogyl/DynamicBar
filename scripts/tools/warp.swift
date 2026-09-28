// Tiny helper: move the hardware cursor to a Cocoa-space point (bottom-left origin)
// and optionally post a real HID mouse-moved event.
//
//   swiftc -O -o /tmp/dbwarp scripts/tools/warp.swift
//   /tmp/dbwarp 896 1105          # warp the cursor (no synthetic event)
//   /tmp/dbwarp --move 896 1105   # warp + post a mouseMoved event
//   /tmp/dbwarp --where           # print current position

import CoreGraphics
import Foundation

func cocoaToQuartz(_ point: CGPoint) -> CGPoint {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    return CGPoint(x: point.x, y: bounds.height - point.y)
}

func quartzToCocoa(_ point: CGPoint) -> CGPoint {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    return CGPoint(x: point.x, y: bounds.height - point.y)
}

func currentCocoaPosition() -> CGPoint {
    guard let event = CGEvent(source: nil) else { return .zero }
    return quartzToCocoa(event.location)
}

let args = CommandLine.arguments

if args.count >= 2, args[1] == "--where" {
    let position = currentCocoaPosition()
    print("\(Int(position.x)) \(Int(position.y))")
    exit(0)
}

let wantsEvent = args.count >= 2 && args[1] == "--move"
let coordinateArgs = wantsEvent ? Array(args.dropFirst(2)) : Array(args.dropFirst(1))

guard coordinateArgs.count >= 2, let x = Double(coordinateArgs[0]), let y = Double(coordinateArgs[1]) else {
    FileHandle.standardError.write(Data("usage: warp [--move] <cocoaX> <cocoaY> | warp --where\n".utf8))
    exit(2)
}

let quartz = cocoaToQuartz(CGPoint(x: x, y: y))
CGWarpMouseCursorPosition(quartz)
CGAssociateMouseAndMouseCursorPosition(1)

if wantsEvent {
    // Posting to the HID tap needs Accessibility permission for *this* helper;
    // when unavailable the warp above still moved the cursor.
    if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartz, mouseButton: .left) {
        event.post(tap: .cghidEventTap)
        print("warped + posted mouseMoved to cocoa(\(Int(x)),\(Int(y)))")
    } else {
        print("warped to cocoa(\(Int(x)),\(Int(y))) (event creation failed)")
    }
} else {
    print("warped to cocoa(\(Int(x)),\(Int(y))) quartz(\(Int(quartz.x)),\(Int(quartz.y)))")
}
