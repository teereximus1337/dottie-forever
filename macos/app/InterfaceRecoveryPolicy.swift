import Foundation

// A page's queued audio mutation cannot survive its renderer/navigation epoch.
// AppKit revokes on main; the serialized runtime checks immediately before I/O.
final class InterfaceCommandFence {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var ready = false
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; ready = false
    }
    func loaded() { lock.lock(); ready = true; lock.unlock() }
    func ticket() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return ready ? generation : nil
    }
    func accepts(_ ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ready && ticket == generation
    }
}

// Main-thread policy for the bundled renderer. Successful navigation alone
// does not forgive a crash loop: the page must stay loaded for a full minute.
struct InterfaceRecoveryPolicy {
    private(set) var attempts = 0
    private(set) var generation: UInt64 = 0
    private var loadedAt: TimeInterval?
    private let delays: [TimeInterval] = [0.25, 1, 3]

    mutating func failed(now: TimeInterval) -> (generation: UInt64, delay: TimeInterval)? {
        if let loadedAt, now - loadedAt >= 60 { attempts = 0 }
        loadedAt = nil
        generation &+= 1
        guard attempts < delays.count else { return nil }
        let delay = delays[attempts]
        attempts += 1
        return (generation, delay)
    }
    mutating func loaded(now: TimeInterval) {
        loadedAt = now
        generation &+= 1
    }
    mutating func retryByUser() {
        attempts = 0
        loadedAt = nil
        generation &+= 1
    }
    func accepts(_ ticket: UInt64) -> Bool { ticket == generation && loadedAt == nil }
}
