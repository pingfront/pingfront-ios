#if canImport(UIKit)
    package import SwiftUI
    package import PingFrontCore

    /// Applies `PingFront.shared.language` to every SDK screen.
    ///
    /// Sets the locale and the layout direction (right to left for Arabic, Hebrew, Persian and Urdu).
    /// Without an override the host's environment stays.
    struct LanguageEnvironment: ViewModifier {
        let tag: String?

        func body(content: Content) -> some View {
            if let tag {
                content
                    .environment(\.locale, Locale(identifier: tag))
                    .environment(\.layoutDirection, Self.direction(tag))
            } else {
                content
            }
        }

        static func direction(_ tag: String) -> LayoutDirection {
            Locale.Language(identifier: tag).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }
    }

    extension View {
        /// The SDK screens' language: the host's `PingFront.shared.language`, else the environment.
        package func pingFrontLanguage(_ pingFront: PingFront) -> some View {
            modifier(LanguageEnvironment(tag: pingFront.language))
        }
    }

    extension L10n {
        /// Strings for the language the SDK runs in now (the override, else the system), outside a view.
        package static var effective: L10n { L10n(LanguageOverride.effectiveLocale) }
    }
#endif
