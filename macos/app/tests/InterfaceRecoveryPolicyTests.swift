import Foundation

@main struct InterfaceRecoveryPolicyTests {
    static func main() {
        let commands = InterfaceCommandFence()
        precondition(commands.ticket() == nil, "Loading pages cannot mutate audio")
        commands.loaded()
        let previous = commands.ticket()!
        precondition(commands.accepts(previous))
        commands.revoke()
        precondition(!commands.accepts(previous) && commands.ticket() == nil,
                     "Renderer loss rejects queued mutations before standby")
        commands.loaded()
        precondition(!commands.accepts(previous), "A newly loaded page cannot revive an old wake command")
        precondition(commands.accepts(commands.ticket()!), "New page commands use the current epoch")
        var policy = InterfaceRecoveryPolicy()
        policy.loaded(now: 0)
        let first = policy.failed(now: 1)!
        precondition(first.delay == 0.25 && policy.accepts(first.generation))
        policy.loaded(now: 2)
        precondition(!policy.accepts(first.generation), "Completed navigation invalidates an old scheduled reload")
        let second = policy.failed(now: 3)!
        precondition(second.delay == 1)
        let third = policy.failed(now: 4)!
        precondition(third.delay == 3 && !policy.accepts(second.generation))
        precondition(policy.failed(now: 5) == nil, "A crash loop exhausts its three automatic reloads")
        precondition(!policy.accepts(third.generation), "Exhaustion invalidates a delayed prior attempt")
        precondition(policy.failed(now: 90) == nil, "Elapsed time without a stable page cannot restart a crash loop")
        policy.retryByUser()
        let manual = policy.failed(now: 91)!
        precondition(manual.delay == 0.25)
        policy.loaded(now: 92)
        let stable = policy.failed(now: 152)!
        precondition(stable.delay == 0.25, "A full minute of stable rendering restores the retry budget")
        print("PASS renderer recovery: queued mutation revocation, bounded backoff, stale callback fencing, explicit retry and stable reset")
    }
}
