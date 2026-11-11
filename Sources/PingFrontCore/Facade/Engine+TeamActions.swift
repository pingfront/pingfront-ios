import Foundation
internal import os

// Team actions ("Fix it for them"): a teammate runs an action from the inbox; the host app does the work and
// answers. Live events carry no seq (no gap repair); `GET /team-actions` catches up after a session starts and
// after every reconnect; answers go through a persistent queue.
extension Engine {
    /// Delivers actions to the host app once per id, skipping ones it already answered.
    func receiveTeamActions(_ payloads: [TeamActionPayload]) async {
        for payload in payloads where !facade.teamActionHub.isKnown(payload.id) {
            // Answered in an earlier launch and still waiting to be sent: the app already did it.
            if await teamActionAcks.contains(payload.id) {
                facade.teamActionHub.answered(payload.id)
                continue
            }
            let action = TeamAction(payload) { [weak self] ack in await self?.answerTeamAction(payload.id, ack) }
            facade.teamActionHub.deliver(action)
        }
    }

    /// Reads the pending actions (an action sent while the app was closed or the socket was down).
    ///
    /// Only with an active session: this never starts one.
    func catchUpTeamActions() {
        guard !preview else { return }
        let session = session
        let client = client
        run { [weak self] in
            guard await session.isActive else { return }
            let generation = await session.generation
            do throws(PingFrontError) {
                let response = try await client.send(Endpoints.teamActions(), reason: .prepare)
                // A logout while the request was in flight: these belong to the previous person.
                guard await session.generation == generation else { return }
                await self?.receiveTeamActions(response.actions)
            } catch {
                Log.network(.info)?.info("Team actions: catch-up failed: \(error.logDescription, privacy: .public)")
            }
            self?.acksWake.notify()
        }
    }

    func answerTeamAction(_ id: String, _ ack: TeamActionAck) async {
        guard facade.teamActionHub.answered(id) else { return }
        await teamActionAcks.enqueue(id: id, ack)
        acksWake.notify()
    }

    /// Sends queued answers whenever woken, with backoff on transient failures.
    func teamActionAcksLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            await acksWake.wait()
            if Task.isCancelled { return }
            // Answers wait for a session; sending them never starts one on launch.
            guard await session.isActive else { continue }
            while !Task.isCancelled {
                let result = await teamActionAcks.drain(teamActionAckSender())
                guard case .retryLater(let error) = result else {
                    attempt = 0
                    break
                }
                let delay: Duration
                if case .coolingDown(_, let remaining) = error {
                    delay = remaining
                } else {
                    delay = Backoff.writes.delay(attempt: attempt)
                    attempt += 1
                }
                await acksWake.wait(timeout: delay, time: time)
            }
        }
    }

    private func teamActionAckSender() -> TeamActionAcks.Send {
        let client = client
        let session = session
        return { item async throws(PingFrontError) in
            let generation = await session.generation
            _ = try await session.token(reason: .prepare)
            guard await session.generation == generation, !Task.isCancelled else { throw .cancelled }
            _ = try await client.send(Endpoints.ackTeamAction(id: item.id, item.ack), reason: .prepare)
        }
    }

    /// Sends queued card action reports: `min(1 s · 2ⁿ, 5 min)` ±20% between retries, or the server's `retryAfter` when
    /// longer; at once when the socket reconnects or the app returns to the foreground (the protocol's retry rules).
    func cardReportsLoop() async {
        var attempt = 0
        let backoff = Backoff.writes
        while !Task.isCancelled {
            await cardReportsWake.wait()
            if Task.isCancelled { return }
            // Reports wait for a session; sending them never starts one on launch.
            guard await session.isActive else { continue }
            while !Task.isCancelled {
                let result = await cardReports.drain(
                    cardReportSender(),
                    stillThere: { [weak self] messageId in
                        await self?.reloadedThreadHas(messageId) ?? false
                    })
                guard case .retryLater(let error) = result else {
                    attempt = 0
                    break
                }
                var delay = backoff.delay(attempt: attempt)
                attempt += 1
                if case .coolingDown(_, let remaining) = error { delay = max(delay, remaining) }
                await cardReportsWake.wait(timeout: delay, time: time)
            }
        }
    }

    /// The thread was reset under a report (409 `thread_reset`): reload it (the outbox stays) and say whether the
    /// report's message is still there.
    func reloadedThreadHas(_ messageId: String) async -> Bool {
        await resetThread()
        return conversation.messages.contains { $0.id == messageId }
    }

    private func cardReportSender() -> CardActionReports.Send {
        let client = client
        let session = session
        return { item async throws(PingFrontError) in
            let generation = await session.generation
            _ = try await session.token(reason: .prepare)
            guard await session.generation == generation, !Task.isCancelled else { throw .cancelled }
            _ = try await client.send(Endpoints.cardAction(cardId: item.cardId, item.request), reason: .prepare)
        }
    }
}
