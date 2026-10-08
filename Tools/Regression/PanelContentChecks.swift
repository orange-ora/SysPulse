import AppKit
import SwiftUI

extension RegressionTests {
    static func panelContentSizing() {
        let suite = "SysPulse.Regression.PanelContent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        func makeContent() -> (PanelContentController, NSHostingController<some View>) {
            let host = NSHostingController(rootView: Text("Machine information").frame(width: 360, height: 571.5))
            host.safeAreaRegions = []
            host.preferredContentSize = NSSize(width: 360, height: 571.5)
            return (PanelContentController(hosting: host, preferences: preferences)!, host)
        }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let (content, host) = makeContent()
        let original = content.naturalContentSize
        check(original == NSSize(width: 360, height: 571.5), "panel content: starts with full natural overview dimensions")
        check(content.view.window == nil, "panel content: sizing tests create no window or installed app")
        var publications: [NSSize] = []
        content.didChangePresentationSize = { publications.append($0) }
        content.acceptMeasuredContentSize(NSSize(width: 360, height: 386.5))
        content.acceptMeasuredContentSize(NSSize(width: 360, height: 382.5))
        check(content.naturalContentSize == original, "panel content: main-queue measurements are deferred")
        drain()
        check(content.naturalContentSize == NSSize(width: 360, height: 382.5), "panel content: latest page measurement wins within one queue turn")
        check(publications == [NSSize(width: 360, height: 382.5)], "panel content: coalesced transient settings sizes publish only once")
        for size in [NSSize(width: 359, height: 100), NSSize(width: CGFloat.nan, height: 100),
                     NSSize(width: 360, height: CGFloat.infinity), NSSize(width: 360, height: 0),
                     NSSize(width: 360, height: -1)] {
            content.acceptMeasuredContentSize(size)
        }
        drain()
        check(content.naturalContentSize.height == 382.5 && publications.count == 1,
              "panel content: invalid and non-360pt measurements cannot overwrite valid layout")
        host.preferredContentSize = original
        content.preferredContentSizeDidChange(for: host)
        check(content.naturalContentSize.height == 382.5, "panel content: stale hosting preferred size cannot override measured page")
        content.suspendSizeUpdates()
        content.acceptMeasuredContentSize(original)
        drain()
        check(content.naturalContentSize.height == 382.5 && publications.count == 1,
              "panel content: open/close suspension retains current natural size")
        content.acceptMeasuredContentSize(NSSize(width: 360, height: 450))
        content.restoreSizeUpdates()
        check(content.naturalContentSize.height == 450, "panel content: pending direct measurement outranks an older drained pending size")
        drain()
        check(publications.count == 2 && content.naturalContentSize.height == 450,
              "panel content: queued drain cannot republish stale size after restore")
        content.suspendSizeUpdates()
        content.acceptMeasuredContentSize(original)
        drain()
        content.restoreSizeUpdates()
        check(content.naturalContentSize == original && publications.count == 3,
              "panel content: overview height restores after settings and animation suspension")
        check(content.prepareFullSizeLayout() == original && content.preferredContentSize == original,
              "panel content: detached full presentation size equals natural size without native insets")
        content.acceptMeasuredContentSize(NSSize(width: 360.2, height: 382.1))
        drain()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        check(content.naturalContentSize.width == 360 &&
              content.naturalContentSize.height == ceil(382.1 * scale) / scale,
              "panel content: accepted subpixel widths normalize and height rounds up at backing scale")
        let document = content.view.subviews.last!
        content.setContraction(1)
        check(abs(document.layer!.transform.m22 - 0.94) < 0.00001 && host.view.frame.size == content.naturalContentSize,
              "panel content: closing shrinks only document drawing while preserving host layout")
        content.setContraction(-1)
        check(document.layer!.transform.m22 == 1, "panel content: negative contraction clamps to natural vertical scale")
        content.setContraction(2)
        check(abs(document.layer!.transform.m22 - 0.94) < 0.00001, "panel content: overrange contraction clamps to six-percent vertical shrink")
        content.setContraction(0)
        check(document.layer!.transform.m22 == 1, "panel content: contraction clears on restore")

        let relay = PanelContentMeasurement()
        relay.receive(NSSize(width: 360, height: 382.5))
        relay.receive(NSSize(width: 100, height: 999))
        let (first, _) = makeContent()
        relay.attach(first)
        drain()
        check(first.naturalContentSize.height == 382.5, "panel measurement: early valid size caches before attachment and invalid size is ignored")
        let (second, _) = makeContent()
        let secondRelay = PanelContentMeasurement()
        secondRelay.attach(second)
        relay.receive(NSSize(width: 360, height: 420))
        drain()
        check(first.naturalContentSize.height == 420 && second.naturalContentSize == original,
              "panel measurement: old root measurement cannot resize a different popover controller")
        weak var released: PanelContentController?
        do {
            let (temporary, _) = makeContent()
            released = temporary
            secondRelay.attach(temporary)
        }
        drain()
        check(released == nil, "panel measurement: relay weak binding does not retain discarded popover controller")
        secondRelay.receive(NSSize(width: 360, height: 400))
        check(second.naturalContentSize == original, "panel measurement: measurements after weak target release do not leak to prior target")
    }
}
