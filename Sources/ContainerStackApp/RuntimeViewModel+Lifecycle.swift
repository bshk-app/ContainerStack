import ContainerStackCore
import Foundation

/// Start, Stop and Restart, one at a time through `lifecycle` (#102).
///
/// Every await inside an operation is followed by a check that its token is still current before
/// it writes state or takes the next step: a superseded operation keeps the queue until that
/// checkpoint, so its CLI step never overlaps the next operation's, and publishes nothing after it.
@MainActor
extension RuntimeViewModel {
    /// The one way to start, stop or restart the runtime. Runs the operation in the caller's task,
    /// after waiting its turn when another one holds the queue.
    func run(
        _ operation: RuntimeOperation,
        origin: RuntimeOperationOrigin,
        observed: Int? = nil
    ) async -> RuntimeOperationOutcome {
        await execute(operation, admit(operation, origin: origin, observed: observed))
    }

    /// Asks the queue at once, so the order of the calls is the order of the requests whatever
    /// order their tasks then run in; `execute` runs what was admitted.
    func admit(
        _ operation: RuntimeOperation,
        origin: RuntimeOperationOrigin,
        observed: Int? = nil
    ) -> LifecycleTurn {
        let turn: LifecycleTurn
        switch lifecycle.request(operation, origin: origin, observed: observed) {
        case .dropped:
            turn = .dropped
        case .runNow(let token):
            turn = .run(token: token)
        case .queued(let id, let replaced):
            supersedeInventoryReads()
            if let replaced {
                lifecycleTickets.removeValue(forKey: replaced)?.settle(runs: false)
            }
            let ticket = LifecycleTicket()
            lifecycleTickets[id] = ticket
            turn = .wait(ticket, token: id)
        }
        isStopping = lifecycle.latest.isStop
        return turn
    }

    func execute(_ operation: RuntimeOperation, _ turn: LifecycleTurn) async -> RuntimeOperationOutcome {
        let token: Int
        switch turn {
        case .dropped:
            return .dropped
        case .run(let admitted):
            token = admitted
        case .wait(let ticket, let id):
            guard await ticket.wait() else { return .superseded }
            token = id
        }

        // A request superseded before its task got here never begins: its first writes would land
        // over the request that superseded it.
        let succeeded = lifecycle.isCurrent(token) ? await perform(operation, token: token) : false

        let outcome: RuntimeOperationOutcome = lifecycle.isCurrent(token) ? .completed(succeeded) : .superseded
        if let next = lifecycle.finish(token) {
            lifecycleTickets.removeValue(forKey: next)?.settle(runs: true)
        } else {
            settle()
        }
        isStopping = lifecycle.latest.isStop
        return outcome
    }

    func stopRuntime(replacingSibling: Bool = false) async {
        _ = await run(.stop(replacingSibling: replacingSibling), origin: .user)
    }

    /// Recovers a wedged runtime: Apple Container can keep answering the API after its vmnet
    /// attachment is gone, and only a full stop/start rebuilds it. `replacingSibling` is for a
    /// restart a person asked for, the only kind that may stop another copy's bridge (F-014).
    @discardableResult
    func restartRuntime(replacingSibling: Bool = false) async -> Bool {
        await run(.restart(replacingSibling: replacingSibling), origin: .user) == .completed(true)
    }

    private func perform(_ operation: RuntimeOperation, token: Int) async -> Bool {
        switch operation {
        case .start: await performStart(token: token)
        case .stop(let replacingSibling): await performStop(replacingSibling: replacingSibling, token: token)
        case .restart(let replacingSibling): await performRestart(replacingSibling: replacingSibling, token: token)
        }
    }

    /// Nothing waits behind the operation that ended, so the phase only a running operation may
    /// hold comes down. `isStarting` matters to the state only while the socket is silent.
    private func settle() {
        isRestarting = false
        guard isStarting else { return }
        isStarting = false
        if runtimeState == .starting {
            applyState(socketResponds: false)
        }
    }

    private func performStart(token: Int) async -> Bool {
        isStarting = true
        isRestarting = false
        // Cleared as the start begins, matching the restart: now that an explicit failure outranks
        // `.starting`, a leftover reason would surface as offline here.
        runtimeFailure = nil
        applyState(socketResponds: false)
        await endRuntimeHelper()
        guard lifecycle.isCurrent(token) else { return false }

        let epoch = inventoryEpoch
        let responds = await socketRespondsNow()
        guard lifecycle.isCurrent(token) else { return false }
        guard responds else {
            guard await launchAndWait(token: token) else { return false }
            await refresh()
            return runtimeState.isHealthy
        }
        // A runtime declared dead during the ping must not be published healthy (#43).
        guard inventoryEpochIsCurrent(epoch) else {
            isStarting = false
            applyState(socketResponds: false)
            return false
        }
        runtimeFailure = nil
        runtimeMessage = "Adopted the Docker socket already serving this machine."
        isStarting = false
        applyState(socketResponds: true)
        // Adopting a socket is exactly when to ask whose bridge it is: this path marks the
        // runtime healthy before the first probe, so the probe's transition branch never fires.
        await adoptBridgeIfStale(during: token)
        guard lifecycle.isCurrent(token) else { return false }
        await refresh()
        return runtimeState.isHealthy
    }

    /// Launches the helper and waits for its socket as one step of the operation holding `token`,
    /// so nothing outside the operation reports on the helper it launched. True once the socket
    /// answers; `isStarting` stays up until the operation ends.
    func launchAndWait(token: Int) async -> Bool {
        // Asked before the helper is spawned rather than read out of its log afterwards. The
        // helper reaches the same verdict and exits, which the app could only report as
        // "helper exited" - a sentence that names neither version nor remedy.
        let complaint = await steps.launchComplaint(runtimeConfiguration())
        guard lifecycle.isCurrent(token) else { return false }
        if let complaint {
            isStarting = false
            failRuntime(complaint)
            return false
        }

        let helper: LaunchedHelper
        do {
            helper = try steps.spawnHelper()
        } catch {
            isStarting = false
            failRuntime("Runtime could not start: \(error)")
            return false
        }
        runtimeProcess = helper.process
        runtimeLogHandle = helper.log
        runtimeLogPath = helper.logPath
        isStarting = true
        runtimeFailure = nil
        errorMessage = nil
        runtimeMessage = "Starting Apple Container and Docker bridge…"
        applyState(socketResponds: false)

        let epoch = inventoryEpoch
        for attempt in 1...60 {
            try? await Task.sleep(for: steps.socketWaitTick)
            guard lifecycle.isCurrent(token) else { return false }
            let responds = await socketRespondsNow()
            guard lifecycle.isCurrent(token) else { return false }
            if responds {
                guard inventoryEpochIsCurrent(epoch) else { return false }
                runtimeFailure = nil
                runtimeMessage = "Runtime ready."
                applyState(socketResponds: true)
                // This app launched this bridge, so its identity is known exactly. Recording it here
                // is what stops the next launch from mistaking a current bridge for a foreign one.
                recordBridgeIdentity()
                hasCheckedBridgeIdentity = true
                return true
            }

            guard helper.process.isRunning else {
                isStarting = false
                failRuntime("Runtime helper exited. Check \(helper.logPath).")
                return false
            }

            runtimeMessage = "Waiting for Docker socket… (\(attempt)/60)"
        }

        isStarting = false
        failRuntime("Docker socket did not become ready within 60 seconds.")
        return false
    }

    private func performStop(replacingSibling: Bool, token: Int) async -> Bool {
        runtimeRecoveryRequested = false
        isStarting = false
        isRestarting = true
        runtimeMessage = "Stopping Docker bridge…"
        await endRuntimeHelper()
        guard lifecycle.isCurrent(token) else { return false }

        let steps = RuntimeRestartPlan.stopSteps(
            configuration: runtimeConfiguration(),
            replacingSibling: replacingSibling
        )
        for step in steps {
            try? await self.steps.control(step)
            guard lifecycle.isCurrent(token) else { return false }
        }
        clearInventoryForStop()
        // Said here rather than left to the probe: a stop is the one silence with a known cause,
        // and `RuntimeLivenessFilter` makes the probe wait for a second opinion it does not need.
        applyState(socketResponds: false)
        runtimeMessage = "Docker bridge stopped."
        await probeAfterControlChange()
        return true
    }

    /// Also runs inline, under Start's token, when Start adopts a bridge from an older build: a
    /// request from inside an operation would be dropped or wait on itself (§3.4).
    func performRestart(replacingSibling: Bool, token: Int) async -> Bool {
        runtimeRecoveryRequested = false
        isRestarting = true
        runtimeFailure = nil
        defer {
            if lifecycle.isCurrent(token) { isRestarting = false }
        }
        // A helper still alive here would make the `.startBridge` step a silent no-op (#71).
        await endRuntimeHelper()
        guard lifecycle.isCurrent(token) else { return false }

        let steps = RuntimeRestartPlan.steps(
            configuration: runtimeConfiguration(),
            agentRegistered: isAgentRegistered,
            replacingSibling: replacingSibling
        )
        var launched = false
        for step in steps {
            runtimeMessage = message(for: step)
            if step == .startBridge {
                guard await launchAndWait(token: token) else { return false }
                launched = true
                continue
            }
            do {
                try await self.steps.control(step)
            } catch {
                guard lifecycle.isCurrent(token) else { return false }
                failRuntime("Restart failed at \(message(for: step)): \(error)")
                return false
            }
            // `container system stop` itself is not interrupted: this is where a superseded
            // restart ends.
            guard lifecycle.isCurrent(token) else { return false }
        }

        // Only the LaunchAgent's restart launches nothing itself, so only it waits here.
        if !launched {
            runtimeMessage = "Waiting for Docker socket…"
        }
        return await completeRuntimeRestart(
            isCurrent: { self.lifecycle.isCurrent(token) },
            waitForSocket: {
                guard !launched else { return true }
                return try await Self.waitForRestartedSocket(delay: self.steps.socketWaitTick) {
                    guard self.lifecycle.isCurrent(token) else { throw CancellationError() }
                    return await self.socketRespondsNow()
                }
            }
        )
    }
}

/// Where an admitted request stands: running, waiting behind the running operation, or dropped.
enum LifecycleTurn {
    case dropped
    case run(token: Int)
    case wait(LifecycleTicket, token: Int)
}

/// A request held back behind the running operation, settled once: true when it may run, false
/// when a newer request replaced it. A decision made before anyone waits on it is kept for them.
@MainActor
final class LifecycleTicket {
    private var decision: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func settle(runs: Bool) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: runs)
        } else {
            decision = runs
        }
    }

    func wait() async -> Bool {
        if let decision { return decision }
        return await withCheckedContinuation { waiter = $0 }
    }
}

extension RuntimeOperation? {
    var isStop: Bool {
        if case .stop = self { true } else { false }
    }
}
