//
//  ScreenCapture.swift
//  Ice
//

import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {
    /// Options that define additional parameters for a capture operation.
    struct CaptureOptions: OptionSet {
        let rawValue: Int

        /// If the `screenBounds` parameter of the capture is `nil`, captures only the window
        /// area and ignores the area occupied by any framing effects.
        static let ignoreFraming = CaptureOptions(rawValue: 1 << 0)

        /// Captures only the shadow effects of the provided windows.
        static let onlyShadows = CaptureOptions(rawValue: 1 << 1)

        /// Fills the partially or fully transparent areas of the capture with a solid white
        /// backing color, resulting in an image that is fully opaque.
        static let shouldBeOpaque = CaptureOptions(rawValue: 1 << 2)

        /// The cursor is shown in the capture.
        static let showsCursor = CaptureOptions(rawValue: 1 << 3)

        /// The output is scaled to fit the configured width and height.
        static let scalesToFit = CaptureOptions(rawValue: 1 << 4)
    }

    /// An error that can occur during a capture operation.
    enum CaptureError: Error {
        /// The app does not have screen capture permissions.
        case missingPermissions

        /// The screen capture manager cannot find a matching window.
        case noMatchingWindow

        /// The screen capture manager cannot find a matching display.
        case noMatchingDisplay

        /// The provided window is not on screen.
        case windowOffScreen

        /// The source rectangle of the capture is outside the bounds of the provided window.
        case sourceRectOutOfBounds

        /// The screen is in an invalid state for capture.
        case invalidScreenState(ScreenState)

        /// The capture operation timed out.
        case timeout
    }

    /// A Boolean value that indicates whether the app has screen capture permissions.
    static var hasPermissions: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Captures the given window as an image.
    ///
    /// - Parameters:
    ///   - window: The window to capture. The window must be on screen.
    ///   - captureRect: The rectangle to capture, relative to the coordinate space of the
    ///     window. Pass `nil` to capture the entire window.
    ///   - resolution: The resolution of the capture.
    ///   - options: Additional parameters for the capture.
    static func captureImage(
        onScreenWindow window: WindowInfo,
        captureRect: CGRect? = nil,
        resolution: SCCaptureResolutionType = .automatic,
        options: CaptureOptions = []
    ) async throws -> CGImage {
        guard hasPermissions else {
            throw CaptureError.missingPermissions
        }

        switch ScreenState.current {
        case .unlocked: break
        case let state: throw CaptureError.invalidScreenState(state)
        }

        let windows = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).windows
        guard let scWindow = windows.first(where: { $0.windowID == window.windowID }) else {
            throw CaptureError.noMatchingWindow
        }

        let displays = try await DisplayInfo.current(activeDisplaysOnly: false)
        guard let display = displays.first(where: { $0.bounds.contains(window.frame) }) else {
            throw CaptureError.noMatchingDisplay
        }

        let sourceRect = try getSourceRect(captureRect: captureRect, window: scWindow)

        let contentFilter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()

        configuration.sourceRect = sourceRect
        configuration.width = Int(sourceRect.width * display.scaleFactor)
        configuration.height = Int(sourceRect.height * display.scaleFactor)
        configuration.captureResolution = resolution
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.ignoreShadowsSingleWindow = options.contains(.ignoreFraming)
        configuration.capturesShadowsOnly = options.contains(.onlyShadows)
        configuration.shouldBeOpaque = options.contains(.shouldBeOpaque)
        configuration.showsCursor = options.contains(.showsCursor)
        configuration.scalesToFit = options.contains(.scalesToFit)

        return try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)
    }

    /// Captures the given window as an image.
    ///
    /// - Parameters:
    ///   - timeout: The amount of time to wait before cancelling the task and throwing a
    ///     timeout error.
    ///   - window: The window to capture. The window must be on screen.
    ///   - captureRect: The rectangle to capture, relative to the coordinate space of the
    ///     window. Pass `nil` to capture the entire window.
    ///   - resolution: The resolution of the capture.
    ///   - options: Additional parameters for the capture.
    static func captureImage(
        timeout: Duration,
        onScreenWindow window: WindowInfo,
        captureRect: CGRect? = nil,
        resolution: SCCaptureResolutionType = .automatic,
        options: CaptureOptions = []
    ) async throws -> CGImage {
        let captureTask = Task {
            let image = try await captureImage(
                onScreenWindow: window,
                captureRect: captureRect,
                resolution: resolution,
                options: options
            )
            try Task.checkCancellation()
            return image
        }

        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            captureTask.cancel()
        }

        do {
            let result = try await captureTask.value
            timeoutTask.cancel()
            return result
        } catch is CancellationError {
            throw CaptureError.timeout
        }
    }

    private static func getSourceRect(captureRect: CGRect?, window: SCWindow) throws -> CGRect {
        let captureRect = captureRect ?? .null
        let windowBounds = CGRect(origin: .zero, size: window.frame.size)
        let sourceRect = if captureRect.isNull {
            windowBounds
        } else {
            captureRect
        }
        guard windowBounds.contains(sourceRect) else {
            throw CaptureError.sourceRectOutOfBounds
        }
        return sourceRect
    }
}

extension ScreenCapture {
    /// Returns an image containing the area of the desktop wallpaper that is below the
    /// menu bar for the given display.
    static func desktopWallpaperBelowMenuBar(for display: DisplayInfo) async throws -> CGImage {
        let windows = try await WindowInfo.onScreenWindows()
        let wallpaperWindow = try await WindowInfo.wallpaperWindow(from: windows, for: display)
        let menuBarWindow = try await WindowInfo.menuBarWindow(from: windows, for: display)
        return try await captureImage(
            timeout: .milliseconds(500),
            onScreenWindow: wallpaperWindow,
            captureRect: CGRect(origin: .zero, size: menuBarWindow.frame.size),
            options: .ignoreFraming
        )
    }
}
