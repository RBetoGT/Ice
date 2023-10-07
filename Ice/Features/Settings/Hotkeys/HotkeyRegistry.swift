//
//  HotkeyRegistry.swift
//  Ice
//

import Carbon.HIToolbox
import Cocoa
import Combine
import OSLog

/// A namespace for the registration, storage, and unregistration
/// of hotkeys.
enum HotkeyRegistry {
    /// Constants representing the possible event kinds that the
    /// hotkey registry can handle.
    enum EventKind {
        case keyUp
        case keyDown

        /// Creates an event kind from the given event reference.
        fileprivate init?(event: EventRef) {
            switch Int(GetEventKind(event)) {
            case kEventHotKeyPressed:
                self = .keyDown
            case kEventHotKeyReleased:
                self = .keyUp
            default:
                return nil
            }
        }
    }

    /// Storable event handler containing the information needed
    /// to cancel a hotkey registration.
    private class EventHandler {
        let eventKind: EventKind
        let key: Hotkey.Key
        let modifiers: Hotkey.Modifiers
        let hotKeyID: UInt32
        var hotKeyRef: EventHotKeyRef?
        let handler: () -> Void

        init(
            eventKind: EventKind,
            key: Hotkey.Key,
            modifiers: Hotkey.Modifiers,
            hotKeyID: UInt32,
            hotKeyRef: EventHotKeyRef,
            handler: @escaping () -> Void
        ) {
            self.eventKind = eventKind
            self.key = key
            self.modifiers = modifiers
            self.hotKeyID = hotKeyID
            self.hotKeyRef = hotKeyRef
            self.handler = handler
        }
    }

    /// Registered event handlers.
    private static var eventHandlers = [UInt32: EventHandler]()

    /// The globally installed event handler reference.
    private static var eventHandlerRef: EventHandlerRef?

    private static var cancellables = Set<AnyCancellable>()

    /// The event types that the registry handles.
    private static let eventTypes: [EventTypeSpec] = [
        EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        ),
        EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased)
        ),
    ]

    /// A four character code that identifies the hotkeys handled
    /// by the registry.
    private static let signature: OSType = {
        let code = "ICEK" // ICEK(ey)
        return NSHFSTypeCodeFromFileType("'\(code)'")
    }()

    /// Installs the global event handler reference, if it hasn't
    /// already been installed.
    private static func installIfNeeded() -> OSStatus {
        guard eventHandlerRef == nil else {
            return noErr
        }

        NotificationCenter.default
            .publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { _ in
                unregisterAndRetainAll()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSMenu.didEndTrackingNotification)
            .sink { _ in
                registerAllRetained()
            }
            .store(in: &cancellables)

        let handler: EventHandlerUPP = { _, event, _ in
            Self.performEventHandler(for: event)
        }
        return InstallEventHandler(
            GetEventDispatcherTarget(),
            handler,
            eventTypes.count,
            eventTypes,
            nil,
            &eventHandlerRef
        )
    }

    /// Registers the given handler for the given hotkey and
    /// event kind, returning the identifier of the registration
    /// on success.
    ///
    /// The returned identifier can be used to unregister the
    /// handler using the ``unregister(_:)`` function.
    ///
    /// - Parameters:
    ///   - hotkey: The hotkey to register the handler with.
    ///   - eventKind: The event kind to register the handler with.
    ///   - handler: The handler to perform when `hotkey` is triggered
    ///     with the event kind specified by `eventKind`.
    ///
    /// - Returns: The registration's identifier on success, `nil`
    ///   on failure.
    static func register(
        hotkey: Hotkey,
        eventKind: EventKind,
        handler: @escaping () -> Void
    ) -> UInt32? {
        enum Context {
            static var currentID: UInt32 = 0
        }

        defer {
            Context.currentID += 1
        }

        var status = installIfNeeded()

        guard status == noErr else {
            Logger.hotkey.error("\(#function) Hotkey event handler installation failed with status \(status)")
            return nil
        }

        let id = Context.currentID

        guard eventHandlers[id] == nil else {
            Logger.hotkey.error("\(#function) Hotkey event handler already stored for id \(id)")
            return nil
        }

        var hotKeyRef: EventHotKeyRef?
        status = RegisterEventHotKey(
            UInt32(hotkey.key.rawValue),
            UInt32(hotkey.modifiers.carbonFlags),
            EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            Logger.hotkey.error("\(#function) Hotkey registration failed with status \(status)")
            return nil
        }

        guard let hotKeyRef else {
            Logger.hotkey.error("\(#function) Hotkey registration failed due to invalid EventHotKeyRef")
            return nil
        }

        let eventHandler = EventHandler(
            eventKind: eventKind,
            key: hotkey.key,
            modifiers: hotkey.modifiers,
            hotKeyID: id,
            hotKeyRef: hotKeyRef,
            handler: handler
        )
        eventHandlers[id] = eventHandler

        return id
    }

    /// Unregisters the handler with the given identifier.
    ///
    /// - Parameter id: An identifier returned from a call to
    ///   the ``register(_:eventKind:handler:)`` function.
    static func unregister(_ id: UInt32) {
        guard let eventHandler = eventHandlers.removeValue(forKey: id) else {
            return
        }
        let status = UnregisterEventHotKey(eventHandler.hotKeyRef)
        if status != noErr {
            Logger.hotkey.error("\(#function) Hotkey unregistration failed with status \(status)")
        }
    }

    private static func unregisterAndRetainAll() {
        for eventHandler in eventHandlers.values {
            let status = UnregisterEventHotKey(eventHandler.hotKeyRef)
            guard status == noErr else {
                Logger.hotkey.error("\(#function) Hotkey unregistration failed with status \(status)")
                continue
            }
            eventHandler.hotKeyRef = nil
        }
    }

    private static func registerAllRetained() {
        for eventHandler in eventHandlers.values {
            guard eventHandler.hotKeyRef == nil else {
                continue
            }

            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(eventHandler.key.rawValue),
                UInt32(eventHandler.modifiers.carbonFlags),
                EventHotKeyID(signature: signature, id: eventHandler.hotKeyID),
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )

            guard
                status == noErr,
                let hotKeyRef
            else {
                eventHandlers.removeValue(forKey: eventHandler.hotKeyID)
                Logger.hotkey.error("\(#function) Hotkey registration failed with status \(status)")
                continue
            }

            eventHandler.hotKeyRef = hotKeyRef
        }
    }

    /// Retrieves and performs the event handler stored under
    /// the identifier for the specified event.
    private static func performEventHandler(for event: EventRef?) -> OSStatus {
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }

        // create a hot key id from the event
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        // make sure creation was successful
        guard status == noErr else {
            return status
        }

        // make sure the event signature matches our signature and
        // that an event handler is registered for the event
        guard
            hotKeyID.signature == signature,
            let eventHandler = eventHandlers[hotKeyID.id],
            eventHandler.eventKind == EventKind(event: event)
        else {
            return OSStatus(eventNotHandledErr)
        }

        // all checks passed; perform the event handler
        eventHandler.handler()

        return noErr
    }
}