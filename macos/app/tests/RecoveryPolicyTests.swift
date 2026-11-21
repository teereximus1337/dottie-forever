import Foundation
@main struct RecoveryPolicyTests {
 static func main() {
    var p = RecoveryPolicy()
    precondition(!p.evaluate(identity: "mic|discord1|dot1", healthy: true, now: 0))
    for t in 1...5 { precondition(!p.evaluate(identity: nil, healthy: false, now: Double(t))) }
    precondition(p.attempts == 0, "Missing exact UID must never select a different microphone")
    precondition(!p.evaluate(identity: "mic|discord2|dot1", healthy: true, now: 6))
    precondition(!p.evaluate(identity: "mic|discord2|dot1", healthy: true, now: 8))
    precondition(p.evaluate(identity: "mic|discord2|dot1", healthy: true, now: 10))
    p.recovered(identity: "mic|discord2|dot1")
    precondition(!p.evaluate(identity: "mic|discord2|dot1", healthy: true, now: 12))
    for t in 13...100 { _ = p.evaluate(identity: "mic|discord2|dot1", healthy: false, now: Double(t)) }
    precondition(p.attempts == 3, "Retry budget bounds persistent failure")
    precondition(!p.evaluate(identity: "mic|discord3|dot1", healthy: false, now: 110))
    p.recovered(identity: "mic|discord2|dot1")
    for t in 111...172 { _ = p.evaluate(identity: "mic|discord2|dot1", healthy: true, now: Double(t)) }
    precondition(p.attempts == 0, "A sustained healthy minute restores retry budget")
    p.reset(); precondition(p.expected == nil && p.attempts == 0)
    p.recovered(identity: "selected")
    p.willSleep()
    for t in 0...30 { precondition(!p.evaluate(identity: "selected", healthy: false, now: Double(t))) }
    precondition(p.attempts == 0, "Sleep must not burn the restart budget")
    p.didWake(now: 31)
    for t in 31..<46 { precondition(!p.evaluate(identity: "selected", healthy: false, now: Double(t))) }
    precondition(!p.evaluate(identity: "selected", healthy: true, now: 46))
    precondition(!p.evaluate(identity: "selected", healthy: true, now: 48))
    precondition(p.evaluate(identity: "selected", healthy: true, now: 50), "Wake reconnects even apparently healthy old capture after settling and debounce")
    precondition(p.nextAttempt == 65, "Failed starts have a longer bounded backoff")
    print("PASS recovery: exact identity, debounce, helper replacement, bounded retries, stable reset")
 }
}
