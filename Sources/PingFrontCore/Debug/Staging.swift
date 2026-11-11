#if DEBUG
    public import Foundation

    @_spi(Marketing)
    extension PingFront {

        /// Stages the connection: offline with messages waiting in the outbox, or back online (the queue empty).
        ///
        /// Debug builds only.
        public func stageDemoConnection(offline: Bool, queued: [String] = []) {
            conversation.live = offline ? .waiting(retryIn: .seconds(4), offline: true) : .stopped
            conversation.pending = queued.enumerated().map { index, text in
                var pending = PendingMessage(clientId: "queued_\(index)", text: text, createdAt: demoNow ?? .now)
                pending.attempts = 1
                return pending
            }
        }

        /// Stages the plan the server knows for the person (the chat's plan status line).
        ///
        /// Debug builds only.
        public func stageDemoPlan(_ entitlement: Entitlement?) {
            person = PersonSummary(id: person?.id ?? "p_demo", level: person?.level ?? .guest, name: person?.name, entitlement: entitlement)
        }

        /// Debug builds only.
        ///
        /// Stages an offline thread and look so the real chat UI can be captured for
        /// marketing screenshots and demos without a server. Stops all network activity for the chat.
        public func stageDemo(
            appName: String,
            appIconPNG: Data? = nil,
            look: ChatLook,
            team: [TeamMember],
            replyExpectation: String?,
            messages: [Message],
            typing: TypingIndicator? = nil,
            teamReadSeq: Int = 0,
            now: Date? = nil
        ) {
            engine?.preview = true
            let host = registry.host
            registry.host = HostAppInfo(
                appName: appName, accent: host?.accent, iconPNG: appIconPNG ?? host?.iconPNG, appVersion: host?.appVersion ?? "1.0")
            previewConfig = AppConfig(
                revision: 1, draft: false, appName: appName, look: look, team: team,
                features: .init(photos: true, reports: true, translation: false, ai: true))
            conversation.team = team
            conversation.replyExpectation = replyExpectation
            conversation.messages = messages
            conversation.pending = []
            conversation.typing = typing
            conversation.teamReadSeq = teamReadSeq
            conversation.live = .stopped
            conversation.phase = .ready
            demoNow = now
            refreshLook()
        }

        /// Opens the staged thread at its top instead of its newest message (audits of the first rows).
        ///
        /// Debug builds only.
        public func stageDemoScrolledToTop(_ top: Bool) { demoScrolledToTop = top }
    }
#endif
