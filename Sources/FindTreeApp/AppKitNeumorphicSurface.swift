import AppKit
import SwiftUI

/// Neumorphic button surface rendered and switched entirely on the AppKit side.
/// Mouse-down/up changes the backing CALayer contents synchronously, avoiding a
/// SwiftUI state/update/render round trip for the visual pressed state.
struct AppKitNeumorphicSurface: NSViewRepresentable {
    let forcePressed: Bool
    let tracksOptionsMenu: Bool
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let distance: CGFloat

    init(
        forcePressed: Bool = false,
        tracksOptionsMenu: Bool = false,
        cornerRadius: CGFloat = 12,
        shadowRadius: CGFloat = 7,
        distance: CGFloat = 5
    ) {
        self.forcePressed = forcePressed
        self.tracksOptionsMenu = tracksOptionsMenu
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.distance = distance
    }

    func makeNSView(context: Context) -> NeumorphicSurfaceView {
        let view = NeumorphicSurfaceView(frame: .zero)
        view.cornerRadius = cornerRadius
        view.shadowRadius = shadowRadius
        view.shadowDistance = distance
        view.forcePressed = forcePressed
        view.tracksOptionsMenu = tracksOptionsMenu
        view.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NeumorphicSurfaceView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.shadowRadius = shadowRadius
        nsView.shadowDistance = distance
        nsView.tracksOptionsMenu = tracksOptionsMenu
        nsView.setForcePressed(forcePressed)
    }

    static func dismantleNSView(_ nsView: NeumorphicSurfaceView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

@MainActor
final class NeumorphicSurfaceView: NSView {
    var cornerRadius: CGFloat = 12 { didSet { invalidateImages() } }
    var shadowRadius: CGFloat = 7 { didSet { invalidateImages() } }
    var shadowDistance: CGFloat = 5 { didSet { invalidateImages() } }
    var tracksOptionsMenu = false
    var forcePressed = false

    private let imageLayer = CALayer()
    private var raisedImage: CGImage?
    private var insetImage: CGImage?
    private var lastRenderSize: CGSize = .zero
    private var lastDarkMode = false
    private var physicalPressed = false
    private var menuTracking = false
    private var lastAppliedPressed: Bool?
    private var eventMonitor: Any?
    private var optionsEventTap: CFMachPort?
    private var optionsEventTapSource: CFRunLoopSource?
    private var optionsEventTapContext: NeumorphicOptionsEventTapContext?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        imageLayer.contentsGravity = .resize
        imageLayer.masksToBounds = false
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let bleed = max(shadowRadius + shadowDistance + 2, 12)
        imageLayer.frame = bounds.insetBy(dx: -bleed, dy: -bleed)
        ensureImages()
        applyPressedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateImages()
        needsLayout = true
    }

    func setForcePressed(_ pressed: Bool) {
        guard forcePressed != pressed else { return }
        forcePressed = pressed
        ensureImages()
        applyPressedAppearance()
    }

    func startMonitoring() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )

        if tracksOptionsMenu {
            startOptionsEventTap()
        }
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        stopOptionsEventTap()
    }

    private func startOptionsEventTap() {
        guard optionsEventTap == nil else { return }

        let context = NeumorphicOptionsEventTapContext(view: self)
        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: neumorphicOptionsEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        optionsEventTapContext = context
        optionsEventTap = tap
        optionsEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopOptionsEventTap() {
        if let source = optionsEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            optionsEventTapSource = nil
        }
        if let tap = optionsEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            optionsEventTap = nil
        }
        optionsEventTapContext = nil
    }

    fileprivate func handleOptionsGlobalMouseDown(at screenPoint: CGPoint) {
        guard tracksOptionsMenu, menuTracking else { return }
        guard !isInsideOwnMenuWindow(screenPoint) else { return }

        // NSMenu consumes outside clicks inside its nested tracking loop, so the
        // normal NSEvent local monitor does not see this mouse-down. Restore the
        // raised surface immediately instead of waiting for didEndTracking.
        menuTracking = false
        physicalPressed = false
        applyPressedAppearance()
    }

    private func isInsideOwnMenuWindow(_ screenPoint: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let ownerPID = Int(ProcessInfo.processInfo.processIdentifier)
        return windows.contains { windowInfo in
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? Int,
                  pid == ownerPID,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 3,
                  let boundsValue = windowInfo[kCGWindowBounds as String]
            else { return false }

            let boundsDictionary = boundsValue as! CFDictionary
            guard let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return false
            }

            // A small tolerance avoids treating a click on the menu border as an
            // outside dismissal. Submenus are also AppKit layer-3 windows.
            return bounds.insetBy(dx: -2, dy: -2).contains(screenPoint)
        }
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard tracksOptionsMenu,
              let menu = notification.object as? NSMenu,
              isOptionsMenu(menu) else { return }
        menuTracking = true
        applyPressedAppearance()
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard tracksOptionsMenu,
              let menu = notification.object as? NSMenu,
              isOptionsMenu(menu) else { return }
        menuTracking = false
        physicalPressed = false
        applyPressedAppearance()
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard let window, event.window === window else {
            if event.type == .leftMouseUp, physicalPressed {
                physicalPressed = false
                applyPressedAppearance()
            }
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let isInside = bounds.contains(location)

        switch event.type {
        case .leftMouseDown:
            guard isInside else { return }
            physicalPressed = true
            applyPressedAppearance()

        case .leftMouseDragged:
            guard physicalPressed else { return }
            physicalPressed = isInside
            applyPressedAppearance()

        case .leftMouseUp:
            guard physicalPressed else { return }
            physicalPressed = false
            applyPressedAppearance()

        default:
            break
        }
    }

    private func applyPressedAppearance() {
        ensureImages()
        let pressed = forcePressed || physicalPressed || menuTracking
        let target = pressed ? insetImage : raisedImage
        guard target != nil, lastAppliedPressed != pressed else { return }
        lastAppliedPressed = pressed

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = target
        CATransaction.commit()
        imageLayer.displayIfNeeded()
        layer?.displayIfNeeded()
    }

    private func invalidateImages() {
        raisedImage = nil
        insetImage = nil
        lastRenderSize = .zero
        lastAppliedPressed = nil
    }

    private func ensureImages() {
        let bleed = max(shadowRadius + shadowDistance + 2, 12)
        let renderSize = CGSize(
            width: max(1, bounds.width + bleed * 2),
            height: max(1, bounds.height + bleed * 2)
        )
        let darkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        guard raisedImage == nil || insetImage == nil || renderSize != lastRenderSize || darkMode != lastDarkMode else {
            return
        }

        lastRenderSize = renderSize
        lastDarkMode = darkMode
        raisedImage = renderSurface(size: renderSize, bleed: bleed, pressed: false, darkMode: darkMode)
        insetImage = renderSurface(size: renderSize, bleed: bleed, pressed: true, darkMode: darkMode)
    }

    private func renderSurface(size: CGSize, bleed: CGFloat, pressed: Bool, darkMode: Bool) -> CGImage? {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = max(1, Int(ceil(size.width * scale)))
        let pixelHeight = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let surface: NSColor
        let highlight: NSColor
        let shadow: NSColor
        if darkMode {
            surface = NSColor(red: 0.16, green: 0.16, blue: 0.175, alpha: 1)
            highlight = NSColor.white.withAlphaComponent(0.16)
            shadow = NSColor.black.withAlphaComponent(0.72)
        } else {
            surface = NSColor(red: 224.0 / 255.0, green: 224.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
            highlight = NSColor.white.withAlphaComponent(0.95)
            shadow = NSColor(red: 0.68, green: 0.68, blue: 0.68, alpha: 0.62)
        }

        let rect = CGRect(
            x: bleed,
            y: bleed,
            width: max(1, size.width - bleed * 2),
            height: max(1, size.height - bleed * 2)
        )
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        if pressed {
            context.addPath(path)
            context.setFillColor(surface.cgColor)
            context.fillPath()

            drawInnerShadow(
                in: context,
                path: path,
                rect: rect,
                color: shadow.withAlphaComponent(0.95).cgColor,
                offset: CGSize(width: shadowDistance - 1, height: -(shadowDistance - 1)),
                blur: 5
            )
            drawInnerShadow(
                in: context,
                path: path,
                rect: rect,
                color: highlight.cgColor,
                offset: CGSize(width: -(shadowDistance - 1), height: shadowDistance - 1),
                blur: 5
            )
        } else {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: shadowDistance, height: -shadowDistance),
                blur: shadowRadius,
                color: shadow.cgColor
            )
            context.addPath(path)
            context.setFillColor(surface.cgColor)
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.setShadow(
                offset: CGSize(width: -shadowDistance, height: shadowDistance),
                blur: shadowRadius,
                color: highlight.cgColor
            )
            context.addPath(path)
            context.setFillColor(surface.cgColor)
            context.fillPath()
            context.restoreGState()

            context.addPath(path)
            context.setFillColor(surface.cgColor)
            context.fillPath()
        }

        return context.makeImage()
    }

    private func drawInnerShadow(
        in context: CGContext,
        path: CGPath,
        rect: CGRect,
        color: CGColor,
        offset: CGSize,
        blur: CGFloat
    ) {
        context.saveGState()
        context.addPath(path)
        context.clip()

        let expansion = max(20, blur * 4 + abs(offset.width) + abs(offset.height))
        let outerRect = rect.insetBy(dx: -expansion, dy: -expansion)
        let inverse = CGMutablePath()
        inverse.addRect(outerRect)
        inverse.addPath(path)

        context.setShadow(offset: offset, blur: blur, color: color)
        context.addPath(inverse)
        context.setFillColor(NSColor.black.cgColor)
        context.drawPath(using: .eoFill)
        context.restoreGState()
    }

    private func isOptionsMenu(_ menu: NSMenu) -> Bool {
        menu.items.contains { item in
            if item.title == "Appearance" { return true }
            if let submenu = item.submenu, isOptionsMenu(submenu) { return true }
            return false
        }
    }
}


private final class NeumorphicOptionsEventTapContext: @unchecked Sendable {
    weak var view: NeumorphicSurfaceView?

    init(view: NeumorphicSurfaceView) {
        self.view = view
    }
}

private let neumorphicOptionsEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard type == .leftMouseDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let context = Unmanaged<NeumorphicOptionsEventTapContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    let screenPoint = event.location

    if Thread.isMainThread {
        MainActor.assumeIsolated {
            context.view?.handleOptionsGlobalMouseDown(at: screenPoint)
        }
    } else {
        Task { @MainActor [weak context] in
            context?.view?.handleOptionsGlobalMouseDown(at: screenPoint)
        }
    }

    return Unmanaged.passUnretained(event)
}
