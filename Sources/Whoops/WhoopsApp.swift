import AppKit
import Combine
import SwiftUI

@main
struct WhoopsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var pendingObservation: AnyCancellable?
    private var lastPendingCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 430, height: 620)
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }

        pendingObservation = model.$pending.sink { [weak self] pending in
            guard let self else { return }
            let previousCount = self.lastPendingCount
            self.lastPendingCount = pending.count
            self.updateStatusItem(pendingCount: pending.count)
            if previousCount == 0 && !pending.isEmpty {
                self.showPopover()
            }
        }
        model.onUserResolvedAll = { [weak self] in
            self?.popover.performClose(nil)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem(pendingCount: Int) {
        guard let button = statusItem?.button else { return }
        let hasPending = pendingCount > 0
        button.image = NSImage(
            systemSymbolName: hasPending ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.branch",
            accessibilityDescription: nil
        )
        button.imagePosition = .imageLeading
        button.title = hasPending ? " \(pendingCount)" : ""
        button.toolTip = hasPending ? "Whoops, \(pendingCount) requests waiting" : "Whoops"
    }
}
