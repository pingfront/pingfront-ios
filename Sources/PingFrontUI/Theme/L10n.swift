#if canImport(UIKit)
    package import Foundation
    package import PingFrontCore

    /// Looks up the SDK's built-in strings for the view's locale (`@Environment(\.locale)`), so previews,
    /// snapshots and in-app language overrides all render the right language.
    ///
    /// Keys are the English text.
    package struct L10n {
        package let locale: Locale

        package init(_ locale: Locale) { self.locale = locale }

        /// The SDK's strings: the module's Swift Package Manager resource bundle.
        static let resources: Bundle = .module

        /// Bundles per language, looked up once.
        private static var bundles: [String: Bundle] = [:]

        private var bundle: Bundle {
            let id = locale.identifier(.bcp47)
            if let cached = Self.bundles[id] { return cached }
            var found = Self.resources
            for candidate in LanguageOverride.candidates(for: locale) {
                if let path = Self.resources.path(forResource: candidate, ofType: "lproj"), let bundle = Bundle(path: path) {
                    found = bundle
                    break
                }
            }
            Self.bundles[id] = found
            return found
        }

        /// The translated string for an English key.
        package func callAsFunction(_ key: String) -> String {
            bundle.localizedString(forKey: key, value: key, table: "Localizable")
        }

        /// The translated format string, filled with `args` (supports plural variations).
        package func callAsFunction(_ key: String, _ args: any CVarArg...) -> String {
            String(format: self(key), locale: locale, arguments: args)
        }

        /// The person's language tag for customer-written `LocalizedText`.
        package var languageTag: String { locale.identifier(.bcp47) }

        /// Customer text in the person's language, or `nil` when unset.
        package func text(_ value: LocalizedText?) -> String? { value?.resolve(for: languageTag) }

        /// The reply expectation: the thread's, else the look's, else the SDK's default.
        ///
        /// The default is "Usually replies within a day", as on the web. An app that turns it off (`showsReplyExpectation`
        /// false) shows none; callers check that.
        @MainActor package func replyExpectation(_ pingFront: PingFront) -> String {
            pingFront.conversation.replyExpectation ?? text(pingFront.look.replyExpectation) ?? self("Usually replies within a day")
        }

        /// The receipt line for a store change.
        package func storeChange(_ change: StoreChange) -> String {
            switch change {
            case .paymentUpdated: self("Payment method updated")
            case .subscribed(let product): self("Subscribed to %@", product)
            case .planChanged(let product): self("Plan changed to %@", product)
            case .autoRenewOff: self("Auto-renew turned off")
            case .autoRenewOn: self("Auto-renew turned back on")
            case .refundRequested: self("Refund requested")
            case .codeRedeemed(let product?): self("Code redeemed: %@", product)
            case .codeRedeemed(nil): self("Code redeemed")
            case .purchasesRestored: self("Purchases restored")
            }
        }

        /// A topic's label: customer text, or the built-in translation for presets.
        package func label(_ topic: ChatTopic) -> String {
            if let custom = text(topic.label) { return custom }
            return self(TopicPreset(rawValue: topic.id)?.label ?? "Other")
        }
    }

    extension TopicSymbol {
        /// The SF Symbol for a topic chip.
        package var systemImage: String {
            switch self {
            case .billing: "creditcard"
            case .bug: "ladybug"
            case .idea: "lightbulb"
            case .question: "questionmark.circle"
            case .account: "person.crop.circle"
            case .feedback: "text.bubble"
            case .gift: "gift"
            case .restore: "arrow.clockwise.circle"
            case .privacy: "hand.raised"
            case .other: "ellipsis.circle"
            }
        }
    }
#endif
