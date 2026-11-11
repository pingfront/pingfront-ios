package import Foundation
internal import os

extension Engine: ConversationDriver {
    package func send(text: String?, photos: [Data], replyTo: CardReply?) {
        noteActivityExternally()
        // The order is fixed now, at the tap: one consumer prepares photos and enqueues jobs in order.
        let placeholder = PendingMessage(clientId: UUID().uuidString.lowercased(), text: text, replyToCard: replyTo)
        stagedSends.append(placeholder)
        conversation.pending.append(placeholder)
        conversation.draft = ""
        sendJobs?.yield(SendJob(message: placeholder, photos: photos, epoch: personEpoch))
    }

    /// Prepares and enqueues sends one at a time, in tap order.
    func sendLoop(_ jobs: AsyncStream<SendJob>) async {
        for await job in jobs {
            if Task.isCancelled { return }
            var prepared: [PendingMessage.Photo] = []
            var bytes: [Data] = []
            var failure: PingFrontError?
            for (index, data) in job.photos.prefix(Limits.imagesPerMessage).enumerated() {
                do {
                    let image = try await ImagePreparation.prepare(data)
                    prepared.append(
                        .init(
                            file: "outbox-\(job.message.clientId)-\(index).jpg", width: image.width, height: image.height,
                            bytes: image.data.count, sha256: image.sha256))
                    bytes.append(image.data)
                } catch {
                    failure = error
                    Log.outbox(.error)?.error("Photo could not be prepared: \(error.logDescription, privacy: .public)")
                }
            }
            if let failure, prepared.count < min(job.photos.count, Limits.imagesPerMessage) {
                // Never send an empty or partial photo message silently, with text or without: show it as failed
                // instead, like Messages' Not Delivered, so the person can try again or delete it.
                if let index = stagedSends.firstIndex(where: { $0.clientId == job.message.clientId }) {
                    stagedSends[index].state = .failed
                    stagedSends[index].failure = Outbox.describe(failure)
                }
                publishPending(await outbox.all())
                continue
            }
            // Logged out or erased while the photos were prepared: the send belonged to the previous person.
            guard job.epoch == personEpoch else { continue }
            var message = job.message
            message.photos = prepared
            await outbox.enqueue(message, photoData: bytes)
            if job.epoch == personEpoch, await !session.isActive { _ = try? await session.token(reason: .chatOpened) }
            outboxWake.notify()
        }
    }

    package func retry(_ clientId: String) {
        // Failed before it reached the outbox (a photo that can't be prepared): Try again sends what can be sent, its
        // text; a photo-only message has nothing left to send and stays failed until it is deleted.
        if let index = stagedSends.firstIndex(where: { $0.clientId == clientId && $0.state == .failed }) {
            var message = stagedSends[index]
            guard message.text?.isEmpty == false else { return }
            message.state = .queued
            message.failure = nil
            stagedSends[index] = message
            if let shown = conversation.pending.firstIndex(where: { $0.clientId == clientId }) { conversation.pending[shown] = message }
            sendJobs?.yield(SendJob(message: message, photos: [], epoch: personEpoch))
            return
        }
        let outbox = outbox
        let wake = outboxWake
        run {
            await outbox.retry(clientId)
            wake.notify()
        }
    }

    package func discard(_ clientId: String) {
        stagedSends.removeAll { $0.clientId == clientId }
        conversation.pending.removeAll { $0.clientId == clientId }
        let outbox = outbox
        let wake = outboxWake
        run {
            await outbox.discard(clientId)
            // A deleted held message no longer keeps the ones behind it waiting.
            wake.notify()
        }
    }

    package func loadOlder() {
        guard !conversation.isLoadingOlder, let first = conversation.messages.first else { return }
        conversation.isLoadingOlder = true
        run { [weak self] in
            defer { self?.conversation.isLoadingOlder = false }
            do throws(PingFrontError) {
                guard let page = try await self?.current(Endpoints.messages(before: first.seq, limit: Limits.pageSize)) else { return }
                self?.conversation.merge(page.messages)
                self?.conversation.hasOlder = page.hasMore
            } catch {
                Log.network(.info)?.info("Load older failed: \(error.logDescription, privacy: .public)")
                // A 409 thread_reset here must reload the thread like anywhere else (scenario thread-reset).
                self?.noteFailure(error)
            }
        }
    }

    package func act(card: Card, messageId: String, answer: CardAnswer?) {
        noteActivityExternally()
        cards.act(card: card, messageId: messageId, answer: answer, offers: offers)
    }

    package func setTyping(_ on: Bool) { typing.setTyping(on) }

    package func reload() {
        guard !preview else { return }
        run { [weak self] in await self?.openThread() }
    }

    package func reloadAndWait() async {
        guard !preview else { return }
        await openThread()
    }

    package func markRead() {
        guard !preview, !isPaused else { return }
        readReceipts.sendNow()
    }

    package func draftChanged(_ text: String) {
        setTyping(!text.isEmpty)
        draftTask?.cancel()
        let persistence = persistence
        let time = time
        draftTask = Task {
            guard await time.pause(Timing.draftSave) else { return }
            if text.isEmpty {
                try? await persistence.remove(Files.draft)
            } else {
                try? await persistence.write(Files.draft, Data(text.utf8))
            }
        }
    }

    package func photoData(_ photo: PendingMessage.Photo) async -> Data? {
        await outbox.photoData(photo)
    }

    package func imageURL(_ part: ImagePart) async -> URL? {
        // Retention deleted it: GET /attachments/{id} would only 404.
        if part.removed { return nil }
        do { return try await uploader.url(for: part.attachmentId) } catch { return part.url }
    }
}

extension Engine {
    func noteActivityExternally() { noteActivity() }

    // MARK: Moments, prepare, reports

    func moment(_ name: String, props: [String: MomentValue]) async -> MomentResult {
        guard MomentGate.isValid(name) else {
            Log.config(.error)?.error("moment: \"\(name, privacy: .private)\" is not a valid name. Use [a-z0-9][a-z0-9_.-]{0,63}.")
            return .invalidName
        }
        do throws(PingFrontError) {
            try await refreshListenedMoments()
            guard await moments.contains(name) else { return .notListened }
            let request = MomentRequest(
                name: name, props: props.isEmpty ? nil : props, occurredAt: .now, clientId: UUID().uuidString.lowercased())
            guard let response = try await current(Endpoints.moment(request), reason: .moment) else {
                return .failed(.cancelled)
            }
            if response.open {
                let present = configuration.presentsChatForMoments
                if present { facade.openChat() }
                return .openRequested(presented: present)
            }
            return switch response.outcome {
            case .ignored: .ignored
            case .scheduled: .scheduled
            case .delivered: .delivered
            case .heldOut: .heldOut
            }
        } catch {
            return .failed(error)
        }
    }

    /// `GET /moments/listened` (key only, no session), at most every 5 minutes.
    func refreshListenedMoments() async throws(PingFrontError) {
        guard await !moments.isFresh() else { return }
        let listened = try await client.send(Endpoints.listenedMoments())
        await moments.update(listened.names, storeEvents: listened.storeEvents)
    }

    /// A store detection from a store module.
    ///
    /// Sent only when a live play listens to that store event
    /// (`ListenedMomentsResponse.storeEvents`), with the signed transaction so the server can verify it.
    func storeEvent(_ event: StoreEventReport) async -> MomentResult {
        guard MomentGate.isValid(event.name) else { return .invalidName }
        // A new install sends nothing at launch: what StoreKit hands over from before this launch (a renewal or a
        // refund while the app was closed) is reported only by an install that already has a session, like the
        // launch sweep of lapses. What happens while the app runs is reported either way.
        if event.occurredAt < launchedAt, await !session.hasInstall() { return .notListened }
        do throws(PingFrontError) {
            try await refreshListenedMoments()
            guard await moments.listensToStoreEvent(event.name) else { return .notListened }
            let request = MomentRequest(
                name: event.name, props: nil, store: event.props, occurredAt: event.occurredAt, clientId: event.clientId)
            let response = try await client.send(Endpoints.moment(request), reason: .moment)
            return switch response.outcome {
            case .ignored: .ignored
            case .scheduled: .scheduled
            case .delivered: .delivered
            case .heldOut: .heldOut
            }
        } catch {
            return .failed(error)
        }
    }

    func prepare() async throws(PingFrontError) {
        do {
            _ = try await session.token(reason: .prepare)
        } catch {
            throw error
        }
    }

    func reportBug(text: String, screenshots: [Data]) async throws(PingFrontError) {
        // Limits count Unicode code points; nothing is truncated silently.
        guard TextLimit.count(text) <= Limits.textChars else {
            throw .invalidInput("The report is longer than \(Limits.textChars) characters.")
        }
        _ = try await session.token(reason: .report)
        var ids: [String] = []
        for data in screenshots.prefix(3) {
            let image = try await ImagePreparation.prepare(data)
            ids.append(
                try await uploader.upload(image.data, width: image.width, height: image.height, sha256: image.sha256, reason: .report))
        }
        let context = await facade.reportContextProvider?.reportContext()
        let tail = context?.logTail.map { UTF8Tail.suffix($0, maxBytes: Limits.reportLogBytes) }
        let request = CreateReportRequest(
            clientId: UUID().uuidString.lowercased(), text: text, screenshotIds: ids, logTail: tail, state: context?.state)
        // Sent either way; the thread shows it only if the same person is still signed in.
        if let response = try await current(Endpoints.report(request), reason: .report) { conversation.merge([response.message]) }
        facade.emit(.reportSent)
    }

    // MARK: Push

    func clearPush() {
        devicePushToken = nil
        unread.pushRegistered = false
        submit(.stage(.push(nil)))
    }

    func setPush(hex: String) {
        devicePushToken = hex
        unread.pushRegistered = true
        #if DEBUG
            let fallback = PushEnvironment.sandbox
        #else
            let fallback = PushEnvironment.production
        #endif
        let environment = configuration.pushEnvironment ?? fallback
        submit(.stage(.push(PushRegistration(provider: .apns, token: hex, environment: environment == .sandbox ? .sandbox : .production))))
    }

    /// A pingfront push arrived in the foreground: take its unread count, or ask the server.
    package func pushReceived(_ payload: PushPayload) {
        switch payload.kind {
        case .message, .ping:
            if let count = payload.unread, !facade.isChatVisible {
                unread.set(count)
            } else {
                let unread = unread
                run { await unread.refresh() }
            }
        case .config:
            let configStore = configStore
            let session = session
            run { [weak self] in
                if let config = await configStore.refresh(testDevice: await session.testDevice, force: true) { self?.applyConfig(config) }
            }
        }
    }

    /// A silent pingfront push (`content-available`, no alert), handled in the background.
    ///
    /// A `config` push refreshes the look. Never starts a session: only an install that already had one refreshes.
    package func backgroundPush(_ payload: PushPayload) async -> BackgroundPushResult {
        switch payload.kind {
        case .config:
            guard !preview, await session.hasInstall() else { return .noData }
            let (config, outcome) = await configStore.refreshReporting(testDevice: await session.testDevice, force: true)
            if let config { applyConfig(config) }
            switch outcome {
            case .changed: return .newData
            case .unchanged: return .noData
            case .failed: return .failed
            }
        case .message, .ping:
            pushReceived(payload)
            return .noData
        }
    }

    package func pushOpened() {
        let session = session
        run { _ = try? await session.token(reason: .pushOpened) }
    }

    // MARK: Logout and erase

    func performLogout() async {
        // Stop sending first: nothing queued for this person may reach the server after logout.
        stopWrites()
        do {
            if let credentials = try await session.installCredentials() { await logouts.add(credentials) }
        } catch {
            // The Keychain is locked (before the first unlock after a restart): the wipe below owes the erase, and the
            // install's POST /me/logout is queued once the Keychain opens (`SessionStore.settleOwedErase()`).
            Log.session(.info)?.notice("Logout while the Keychain is locked: the erase waits for protected data")
        }
        await wipeLocal()
        startOutboxLoop()
        await drainPendingLogouts()
    }

    func erase() async throws(PingFrontError) {
        let known: InstallCredentials?
        do { known = try await session.installCredentials() } catch { throw .protectedDataUnavailable }
        guard let credentials = known else {
            await wipeLocal()
            return
        }
        // Nothing may send for this person, refresh or re-register them while DELETE /me is in flight.
        stopWrites()
        await session.beginErase()
        do throws(PingFrontError) {
            _ = try await client.send(Endpoints.eraseMe(credentials))
        } catch  where error.code == .notFound || error.code == .sessionRevoked {
            // Already erased (an earlier attempt whose response was lost): the local wipe still happens.
            Log.session(.info)?.info("Erase: already done on the server")
        } catch {
            // Nothing is restored; the person can retry the erase (it is idempotent).
            await session.endErase(erased: false)
            startOutboxLoop()
            throw error
        }
        await session.endErase(erased: true)
        await wipeLocal()
        startOutboxLoop()
    }

    /// `GET /me/export`: the person's `PersonExport` as the server sent it.
    ///
    /// An explicit call from the host app, like `prepare()`, so it may start the session (reason `prepare`).
    /// Nothing is stored or logged; the bytes go straight back to the caller.
    func exportMyData() async throws(PingFrontError) -> Data {
        let data = try await client.send(Endpoints.exportMe(), reason: .prepare)
        guard await Self.isExport(data) else { throw .invalidResponse("Unexpected response from the server") }
        return data
    }

    /// Hands over only what is recognisably an export: a JSON object naming its format.
    ///
    /// Parsed off the main actor (an export can be large).
    @concurrent nonisolated static func isExport(_ data: Data) async -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["format"] is String
    }

    /// Why the person's local data goes.
    enum LocalWipe {
        /// Logout or erase: the session store forgets the install and the staged profile too.
        case forgotten
        /// The server revoked the install: the session store already dropped its credentials and keeps the staged
        /// profile for the next guest; token requests wait until this wipe is done.
        case revoked
    }

    /// Drops everything local that belonged to the person: one routine for logout, erase and a revoked install.
    func wipeLocal(_ kind: LocalWipe = .forgotten) async {
        personEpoch += 1
        // A draft save still waiting for its debounce would write the previous person's text back.
        draftTask?.cancel()
        draftTask = nil
        cards.cancelAll()
        facade.cancelChatLink()
        await live.stop()
        if kind == .forgotten { await session.wipe() }
        await outbox.clear()
        await teamActionAcks.clear()
        await cardReports.clear()
        facade.teamActionHub.reset()
        await configStore.clearDraft()
        await threadCache.clear()
        await api.threadRevision.set(nil)
        await uploader.clear()
        try? await persistence.remove(Files.draft)
        stagedSends = []
        // The push token is the device's, not the person's: it goes with the next install's first PATCH (apps
        // register for notifications once per launch, so it would never come again). Without one, poll for unread.
        if let token = devicePushToken { setPush(hex: token) } else { unread.pushRegistered = false }
        conversation.clear()
        unread.set(0)
        facade.person = nil
        facade.isTestDevice = false
        facade.storeAccountToken = nil
        facade.lastIdentityProblem = nil
        facade.runWipeHandlers()
        // Only now may a token request start a new guest: nothing queued for the revoked install is left to go out.
        if kind == .revoked { await session.endRevoke() }
    }

    /// `POST /me/logout` for every install this device logged out of, until each succeeds.
    func drainPendingLogouts() async {
        // An install a logout could not erase while the Keychain was locked is logged out now.
        for credentials in await session.settleOwedErase() { await logouts.add(credentials) }
        await logouts.drain(api: api)
    }
}
