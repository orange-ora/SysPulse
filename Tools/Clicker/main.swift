import CoreGraphics
import Foundation

// 用法: Clicker <x> <y>   在屏幕坐标（左上原点，点）点击一次
guard CommandLine.arguments.count >= 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    print("用法: Clicker <x> <y>"); exit(1)
}
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
    event.post(tap: .cghidEventTap)
}

post(.mouseMoved)
usleep(150_000)
post(.leftMouseDown)
usleep(90_000)
post(.leftMouseUp)
print("clicked at \(Int(x)),\(Int(y))")
