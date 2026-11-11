internal import os

/// Coalesces profile changes for 250 ms and sends one `PATCH /me` with only the changed fields.
/// Owns the staged and last-sent profile. Sends nothing until a session exists (no network at launch).
///
/// The device context never makes a PATCH of its own: it is added only to a PATCH that has something else to send.
package actor PatchCoalescer {
    package typealias Sender = @Sendable (UpdateMeRequest) async throws(PingFrontError) -> UpdateMeResponse

    private var staged = Profile()
    private var sent = Profile()
    private var active = false
    private var flushTask: Task<Void, Never>?
    private var failures = 0
    /// One PATCH at a time, so the server applies changes in the order they were staged.
    private var isSending = false
    /// Bumped by `reset()`: a PATCH that was in flight at logout never reports its response.
    private var epoch: UInt64 = 0
    private let window: Duration
    private let time: TimeSource
    private let backoff = Backoff()
    private var sender: Sender?
    private let context: ContextReporter?
    /// The registered screens ride on a PATCH that goes anyway, when they changed since this install sent them.
    private let screens: ScreensReporter?
    /// The device facts the server last saw, the base a context rides on when nothing else about the device changed.
    private var knownDevice: Device?
    private let responses: AsyncStream<UpdateMeResponse>.Continuation
    /// Responses of successful PATCHes (identity problems surface here).
    package nonisolated let responseStream: AsyncStream<UpdateMeResponse>

    package init(
        time: TimeSource, window: Duration = Timing.patchWindow, context: ContextReporter? = nil, screens: ScreensReporter? = nil
    ) {
        self.time = time
        self.window = window
        self.context = context
        self.screens = screens
        (responseStream, responses) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    package func setSender(_ sender: @escaping Sender) { self.sender = sender }

    /// Stages a change.
    ///
    /// If a session is active, a flush is scheduled after the coalescing window.
    package func stage(_ change: ProfileChange) {
        staged.apply(change)
        scheduleFlush(after: window)
    }

    /// The staged profile, included whole in `POST /sessions`.
    package func stagedProfile() -> Profile { staged }

    /// Bumped by `reset()`: the session store tags a session request with it, so an answer that lands after a logout
    /// never marks or activates anything for the next person.
    package var resets: UInt64 { epoch }

    /// Marks `profile` as delivered (it went out with the session request), unless `reset()` ran since `resets` was
    /// `epoch`.
    package func markSent(_ profile: Profile, epoch expected: UInt64? = nil) {
        guard expected.map({ $0 == epoch }) ?? true else { return }
        sent = profile
        if let device = profile.device { knownDevice = device }
    }

    /// The server refused the identity: forget it, staged and sent, so it is never sent again.
    package func dropIdentity() {
        staged.identity = nil
        sent.identity = nil
    }

    /// The server saw these device facts (session refresh); later changes go out in a PATCH.
    package func markDeviceSent(_ device: Device, epoch expected: UInt64? = nil) {
        guard expected.map({ $0 == epoch }) ?? true else { return }
        sent.device = device
        knownDevice = device
        if staged.device == nil { staged.device = device }
    }

    /// A session now exists: send anything staged that the server has not seen (unless `reset()` ran since `resets`
    /// was `epoch`: that session belonged to the previous person).
    package func activate(epoch expected: UInt64? = nil) {
        guard expected.map({ $0 == epoch }) ?? true else { return }
        active = true
        scheduleFlush(after: window)
    }

    /// Logout: forget everything staged and sent, stop sending until the next session.
    package func reset() {
        epoch += 1
        flushTask?.cancel()
        flushTask = nil
        staged = Profile()
        sent = Profile()
        knownDevice = nil
        active = false
        failures = 0
        isSending = false
    }

    /// The pending patch, for tests and diagnostics.
    package func pendingPatch() -> UpdateMeRequest { staged.patch(since: sent) }

    private func scheduleFlush(after delay: Duration) {
        // While a PATCH is in flight, the completion reschedules; never start a second request.
        guard active, flushTask == nil, !isSending else { return }
        flushTask = Task { [time] in
            guard await time.pause(delay) else { return }
            await self.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard active, let sender else { return }
        let snapshot = staged
        var patch = snapshot.patch(since: sent)
        guard !patch.isEmpty else { return }
        isSending = true
        let started = epoch
        // Context rides along with what goes out anyway, on the full device facts the server already has.
        var draft: ContextReporter.Draft?
        if let context, let base = patch.device ?? snapshot.device ?? sent.device ?? knownDevice,
            let next = await context.draft(for: .patch)
        {
            var device = base
            device.context = next.context
            patch.device = device
            draft = next
        }
        // The screens, like the context, never make a PATCH of their own: only on one that goes anyway.
        var screensDraft: ScreensReporter.Draft?
        if let screens, let base = patch.device ?? snapshot.device ?? sent.device ?? knownDevice,
            let next = await screens.ifChanged(installId: base.installId, appVersion: base.app.version)
        {
            var device = base
            device.app.screens = next.screens
            patch.device = device
            screensDraft = next
        }
        guard active, started == epoch else {
            isSending = false
            return
        }
        do {
            let response = try await sender(patch)
            isSending = false
            // Logged out while the PATCH was in flight: its answer belongs to the previous person.
            guard active, started == epoch else { return }
            sent = snapshot
            failures = 0
            if let device = snapshot.device { knownDevice = device }
            if let draft { await context?.delivered(draft) }
            if let screensDraft, let installId = patch.device?.installId { await screens?.delivered(screensDraft, installId: installId) }
            // Every valid field was applied; the rejected ones count as sent too, so they leave the pending
            // patch and are never retried (they would be rejected again).
            if !response.rejected.isEmpty {
                for field in response.rejected {
                    Log.session(.error)?.error("PATCH /me rejected \(field.field, privacy: .private): \(field.code, privacy: .private)")
                }
                // A refused identity is dropped for good, staged and sent, so no later request carries it.
                if response.rejected.contains(where: { $0.field.split(separator: ".").first == "identity" }) {
                    staged.identity = nil
                    sent.identity = nil
                }
            }
            responses.yield(response)
            // Changes staged while the request was in flight go out in the next window.
            if !staged.patch(since: sent).isEmpty { scheduleFlush(after: window) }
        } catch {
            isSending = false
            guard active, started == epoch else { return }
            failures += 1
            Log.session(.error)?.error("PATCH /me failed: \(error.logDescription, privacy: .public)")
            if error.isTransient {
                scheduleFlush(after: backoff.delay(attempt: failures - 1))
            } else if case .server(let server) = error, server.status == 422 {
                // Context the server refused is not sent again until it changes.
                if let draft, server.fields.isEmpty || server.fields.contains(where: { $0.hasPrefix("device.context") }) {
                    await context?.delivered(draft)
                }
                // The named fields are invalid: drop them and send the rest. Without names, drop the whole patch.
                if server.fields.isEmpty { sent = snapshot } else { staged.revert(paths: server.fields, to: sent) }
                if !staged.patch(since: sent).isEmpty { scheduleFlush(after: window) }
            }
        }
    }
}
