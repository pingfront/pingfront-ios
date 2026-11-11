import Foundation

/// Everything the SDK reports about the person.
///
/// Staged in memory only (never UserDefaults).
package struct Profile: Sendable, Equatable {
    /// The device facts the server last saw (set from the session; changes go out in `PATCH /me`).
    package var device: Device?
    package var identity: Identity?
    package var traits: [String: String] = [:]
    package var entitlement: Entitlement?
    package var offers: [OfferSlot]?
    package var push: PushRegistration?
    package var hostLook: HostLook?

    package init() {}

    /// The `PATCH /me` body that turns `sent` into `self`: only changed fields, only changed trait keys.
    package func patch(since sent: Profile) -> UpdateMeRequest {
        var request = UpdateMeRequest()
        if device != sent.device, let device { request.device = device }
        if identity != sent.identity, let identity { request.identity = identity }
        let changedTraits = traits.filter { sent.traits[$0.key] != $0.value }
        if !changedTraits.isEmpty { request.traits = changedTraits }
        if entitlement != sent.entitlement, let entitlement { request.entitlement = entitlement }
        if offers != sent.offers, let offers { request.offers = offers }
        if push != sent.push {
            request.push = push.map(UpdateMeRequest.PushChange.set) ?? .clear
        }
        if hostLook != sent.hostLook, let hostLook { request.hostLook = hostLook }
        return request
    }
}

/// One change to the staged profile.
package enum ProfileChange: Sendable {
    case identity(Identity?)
    case traits([String: String])
    case entitlement(Entitlement?)
    case offers([OfferSlot])
    case push(PushRegistration?)
    case hostLook(HostLook)
    case device(Device)
}

extension Profile {
    package mutating func apply(_ change: ProfileChange) {
        switch change {
        case .identity(let value): identity = value
        case .traits(let value):
            // At most `Limits.traits` keys in total: existing keys always update, new keys stop at the cap.
            for (key, item) in value.sorted(by: { $0.key < $1.key }) where traits[key] != nil || traits.count < Limits.traits {
                traits[key] = item
            }
        case .entitlement(let value): entitlement = value
        case .offers(let value): offers = value
        case .push(let value): push = value
        case .hostLook(let value): hostLook = value
        case .device(let value): device = value
        }
    }

    /// Drops fields the server refused (`rejected[].field` or a 422's `fields[]`) from `self`, so they stop
    /// appearing in the patch since `sent`.
    ///
    /// Paths are dotted: `traits.plan`, `identity.email`, `offers`.
    package mutating func revert(paths: [String], to sent: Profile) {
        for path in paths {
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            switch parts.first {
            case "device": device = sent.device
            case "identity": identity = sent.identity
            case "traits":
                if parts.count == 2 { traits[parts[1]] = sent.traits[parts[1]] } else { traits = sent.traits }
            case "entitlement": entitlement = sent.entitlement
            case "offers": offers = sent.offers
            case "push": push = sent.push
            case "hostLook": hostLook = sent.hostLook
            default: break
            }
        }
    }
}
