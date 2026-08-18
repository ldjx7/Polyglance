@MainActor
public final class AuxiliaryWindowCoordinator<Window: AnyObject> {
    public private(set) var window: Window?

    private let makeWindow: () -> Window
    private let present: (Window) -> Void
    private let closeWindow: (Window) -> Void

    public init(
        makeWindow: @escaping () -> Window,
        present: @escaping (Window) -> Void,
        close: @escaping (Window) -> Void
    ) {
        self.makeWindow = makeWindow
        self.present = present
        closeWindow = close
    }

    public func show() {
        let window = window ?? makeAndStoreWindow()
        present(window)
    }

    public func close() {
        guard let window else {
            return
        }
        closeWindow(window)
    }

    /// Releases the cached window so the next `show()` rebuilds its content.
    /// Callers can use this after a real close to avoid preserving unsaved UI
    /// state in a window whose AppKit object is intentionally not released.
    public func discard() {
        window = nil
    }

    private func makeAndStoreWindow() -> Window {
        let newWindow = makeWindow()
        window = newWindow
        return newWindow
    }
}
