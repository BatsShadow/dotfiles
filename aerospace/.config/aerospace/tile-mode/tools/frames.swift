// Emits on-screen normal windows in front-to-back z-order as TSV:
//   z<TAB>windowId<TAB>x<TAB>y<TAB>w<TAB>h
// Uses CGWindowList (no screen-recording permission needed, no focus side effects).
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var z = 0
for w in list {
    guard (w[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let x = Int(b["X"] as? Double ?? 0), y = Int(b["Y"] as? Double ?? 0)
    let ww = Int(b["Width"] as? Double ?? 0), hh = Int(b["Height"] as? Double ?? 0)
    if ww < 120 || hh < 120 { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    print("\(z)\t\(num)\t\(x)\t\(y)\t\(ww)\t\(hh)")
    z += 1
}
