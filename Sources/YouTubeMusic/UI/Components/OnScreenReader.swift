import AppKit
import SwiftUI

/// Reports whether the window a view sits in is actually on screen.
///
/// SwiftUI keeps the views of a hidden window alive: the menu bar panel's content exists
/// from launch whether or not the panel is open, and a minimised or covered window keeps
/// its views too. A `TimelineView` in one of them redraws on schedule regardless — the
/// menu bar panel's scrubber alone kept the main thread ~20% busy while music played,
/// with nothing on screen. Views with continuous motion pause on this.
///
/// `onChange` is called on transitions only, starting from "not on screen", so a
/// `true` is always followed by a `false` before the view goes away.
struct OnScreenReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var isOnScreen = false
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                // Covers closing, minimising, hiding the app, being covered by other
                // windows and the menu bar panel being dismissed.
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
            refresh()
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            report(false)
        }

        private func refresh() {
            report(window?.occlusionState.contains(.visible) ?? false)
        }

        private func report(_ visible: Bool) {
            guard visible != isOnScreen else { return }
            isOnScreen = visible
            // Not during SwiftUI's own update pass (this runs from view insertion).
            let onChange = onChange
            DispatchQueue.main.async { onChange?(visible) }
        }
    }
}
