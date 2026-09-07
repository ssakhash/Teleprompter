import AppKit
import Carbon
import TeleprompterKit

@MainActor final class HotKeyController {
    private weak var model: AppModel?
    private var registrations: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var currentKeys: [String: UInt32] = [:]
    private let actions = ["record", "pause", "previous", "next"]
    init(model: AppModel) {
        self.model = model
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers registered hotkeys through the application's main event loop.
            MainActor.assumeIsolated {
                Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue().invoke(Int(id.id))
            }
            return noErr
        }, 1, &event, context, &handler)
    }

    func register(_ keys: [String: UInt32]) throws {
        let values = actions.compactMap { keys[$0] }
        guard values.count == actions.count, Set(values).count == values.count else {
            throw TeleprompterError.message("Each keyboard shortcut needs a different key. Existing shortcuts were retained.")
        }
        let previous = currentKeys
        unregister()
        do { try install(keys); currentKeys = keys }
        catch {
            unregister()
            if !previous.isEmpty { try? install(previous) }
            throw error
        }
    }

    private func unregister() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations.removeAll()
    }

    private func install(_ keys: [String: UInt32]) throws {
        for (index, action) in actions.enumerated() {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(keys[action]!, UInt32(controlKey | optionKey | cmdKey),
                EventHotKeyID(signature: 0x5450524D, id: UInt32(index)), GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else {
                throw TeleprompterError.message("Could not register the \(action) shortcut. It may be used by another app; choose another key.")
            }
            registrations.append(reference)
        }
    }

    private func invoke(_ index: Int) {
        switch index {
        case 0: model?.toggleRecording()
        case 1: model?.toggleFollowing()
        case 2: model?.moveSentence(-1)
        case 3: model?.moveSentence(1)
        default: break
        }
    }
}
