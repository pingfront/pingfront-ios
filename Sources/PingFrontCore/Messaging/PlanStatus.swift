package import Foundation

/// The person's plan as one line in the chat: "Ledgerly Plus renews 12 Nov", "Payment issue: update by 3 Nov".
package enum PlanStatus: Equatable, Sendable {
    /// Auto-renews on the date (active or trial).
    case renews(Date)
    /// Cancelled: access ends on the date.
    case ends(Date)
    /// Ended on the date.
    case ended(Date)
    /// A payment problem; access ends on the date unless it's fixed (`nil` when the store gave no date).
    case paymentIssue(until: Date?)
    /// Owned for good.
    case lifetime

    /// The line for an entitlement, or `nil` when there is nothing worth saying (no plan, unknown state, no date).
    package init?(_ entitlement: Entitlement, now: Date = .now) {
        switch entitlement.state {
        case .grace, .billingRetry:
            self = .paymentIssue(until: entitlement.gracePeriodEndsAt.flatMap { $0 > now ? $0 : nil })
        case .active, .trial:
            guard let date = entitlement.renewsAt ?? entitlement.expiresAt, date > now else { return nil }
            self = entitlement.renewsAt != nil ? .renews(date) : .ends(date)
        case .cancelled:
            guard let date = entitlement.expiresAt else { return nil }
            self = date > now ? .ends(date) : .ended(date)
        case .expired:
            guard let date = entitlement.expiresAt else { return nil }
            self = .ended(date)
        case .lifetime:
            self = .lifetime
        case .none, .unknown:
            return nil
        }
    }

    /// True when the line should carry the "Update payment method" action.
    package var needsPaymentFix: Bool {
        if case .paymentIssue = self { return true }
        return false
    }
}
