// HapticDriver.swift — прямой доступ к Taptic Engine из Swift (нужен метроному).
// Тот же приём, что в mactic/midi_haptic: приватный MultitouchSupport.framework
// грузится через dlopen/dlsym (на ARM иначе PAC даёт bus error).
// Хэндлы — сырые указатели (void*), retain-баланс вручную: Create даёт +1,
// гасим через Unmanaged.release(). Хэндл актуатора одноразовый:
// под каждый удар создаётся новый.
import Foundation

final class HapticDriver {

    private typealias FnCreateList = @convention(c) () -> UnsafeRawPointer?
    private typealias FnCreateAct = @convention(c) (UInt64) -> UnsafeRawPointer?
    private typealias FnOpen = @convention(c) (UnsafeRawPointer, UInt32) -> Int32
    private typealias FnClose = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias FnActuate = @convention(c) (UnsafeRawPointer, Int32, UInt32, UInt32, UInt32) -> Int32

    private var fnCreateList: FnCreateList?
    private var fnCreateAct: FnCreateAct?
    private var fnOpen: FnOpen?
    private var fnClose: FnClose?
    private var fnActuate: FnActuate?

    private(set) var deviceID: Int64 = -1
    var ready: Bool { deviceID >= 0 }

    init?() {
        guard let h = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else { return nil }
        // хэндл dlopen не закрываем — символы должны жить
        fnCreateList = cast(dlsym(h, "MTDeviceCreateList"))
        fnCreateAct = cast(dlsym(h, "MTActuatorCreateFromDeviceID"))
        fnOpen = cast(dlsym(h, "MTActuatorOpen"))
        fnClose = cast(dlsym(h, "MTActuatorClose"))
        fnActuate = cast(dlsym(h, "MTActuatorActuate"))
        guard fnCreateList != nil, fnCreateAct != nil, fnOpen != nil,
              fnClose != nil, fnActuate != nil else { return nil }
        guard let id = findDevice() else { return nil }
        deviceID = id
    }

    private func cast<T>(_ sym: UnsafeMutableRawPointer?) -> T? {
        guard let s = sym else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private func release(_ p: UnsafeRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(p).release()
    }

    private func findDevice() -> Int64? {
        guard let listPtr = fnCreateList!() else { return nil }
        let arr = Unmanaged<CFArray>.fromOpaque(listPtr).takeRetainedValue()
        let n = CFArrayGetCount(arr)
        for i in 0 ..< n {
            guard let dev = CFArrayGetValueAtIndex(arr, i) else { continue }
            var id: UInt64 = 0
            memcpy(&id, dev.advanced(by: 64), 8)
            guard let act = fnCreateAct!(id) else { continue }
            let r = fnOpen!(act, 0)
            _ = fnClose!(act)
            release(act)
            if r == 0 { return Int64(bitPattern: id) }
        }
        return nil
    }

    /// Один удар. Возвращает true, если актуатор принял команду.
    @discardableResult
    func fire(_ waveform: Int32) -> Bool {
        guard deviceID >= 0 else { return false }
        guard let act = fnCreateAct!(UInt64(bitPattern: deviceID)) else { return false }
        let r: Int32
        if fnOpen!(act, 0) == 0 {
            r = fnActuate!(act, waveform, 0, 0, 0)
        } else {
            r = -1
        }
        _ = fnClose!(act)
        release(act)
        return r == 0
    }
}
