import Foundation

// Serialized by NativeRuntime.queue. No HAL calls or device-name fallback.
struct RecoveryPolicy {
    var expected: String?
    var candidate: String?
    var observations = 0
    var attempts = 0
    var nextAttempt: TimeInterval = 0
    var healthySince: TimeInterval?
    var suspended = false
    var resumeAfter: TimeInterval = 0
    mutating func willSleep() { suspended = true; candidate = nil; observations = 0; healthySince = nil }
    mutating func didWake(now: TimeInterval) {
        suspended = false; resumeAfter = now + 15
        expected = "resume-requires-reconnect"
        candidate = nil; observations = 0; healthySince = nil
    }
    mutating func reset() { self = RecoveryPolicy() }
    mutating func evaluate(identity: String?, healthy: Bool, now: TimeInterval) -> Bool {
        guard !suspended, now >= resumeAfter else { return false }
        guard let identity else { candidate = nil; observations = 0; healthySince = nil; return false }
        if expected == nil { expected = identity }
        if healthy && identity == expected {
            candidate = nil; observations = 0
            if healthySince == nil { healthySince = now }
            if now - (healthySince ?? now) >= 60 { attempts = 0 }
            return false
        }
        healthySince = nil
        if candidate == identity { observations += 1 } else { candidate = identity; observations = 1 }
        guard observations >= 3, attempts < 3, now >= nextAttempt else { return false }
        attempts += 1; nextAttempt = now + Double(15 * (1 << (attempts - 1)))
        observations = 0
        return true
    }
    mutating func recovered(identity: String) { expected = identity; candidate = nil; observations = 0 }
}
