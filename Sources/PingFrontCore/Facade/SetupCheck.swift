import Foundation

/// The result of `PingFront.selfCheck()`: whether a real message reached the server, and if not, a stable code and
/// what to do.
///
/// Nothing in it is personal: codes and advice are the SDK's own.
public struct SetupCheckResult: Sendable, Equatable {
    /// True when the setup message reached the server.
    public let passed: Bool
    /// A stable failure code, such as `key_unknown`, `network`, `timeout`, `app_paused` or `identity_user_mismatch`.
    /// `nil` when passed.
    public let code: String?
    /// What to do about the failure, in English. `nil` when passed.
    public let advice: String?

    /// A passing result.
    public static let pass = SetupCheckResult(passed: true, code: nil, advice: nil)

    package init(passed: Bool = false, code: String?, advice: String?) {
        self.passed = passed
        self.code = code
        self.advice = advice
    }

    /// The one-line form: `PingFront self-check: PASS` or `PingFront self-check: FAIL <code>: <advice>`.
    public var line: String {
        passed ? "PingFront self-check: PASS" : "PingFront self-check: FAIL \(code ?? "unexpected"): \(advice ?? "")"
    }
}

extension Engine {
    /// Sends "Setup check from <app>" and waits for the server (at most `timeout`).
    package func setupCheck(timeout: Duration = .seconds(20)) async -> SetupCheckResult {
        let appName = facade.hostApp?.appName ?? DeviceInfo.appDisplayName
        let client = client
        let time = time
        let result: Result<Void, PingFrontError>? = await withTaskGroup(of: Result<Void, PingFrontError>?.self) { group in
            group.addTask {
                do throws(PingFrontError) {
                    let request = SendMessageRequest(
                        clientId: UUID().uuidString.lowercased(), text: "Setup check from \(appName)", attachmentIds: nil,
                        replyToCard: nil)
                    _ = try await client.send(Endpoints.sendMessage(request), reason: .prepare)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                _ = await time.pause(timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if case .success? = result, let problem = facade.lastIdentityProblem { return SetupCheck.result(forIdentity: problem) }
        if case .success? = result, let problem = facade.configurationProblem, problem.kind == .keychain {
            return SetupCheckResult(code: "keychain", advice: problem.message)
        }
        return SetupCheck.result(for: result)
    }
}

package enum SetupCheck {
    /// Maps the outcome to the result.
    package static func result(for result: Result<Void, PingFrontError>?) -> SetupCheckResult {
        switch result {
        case .success?:
            return .pass
        case nil:
            return SetupCheckResult(
                code: "timeout", advice: "The server did not answer within 20 seconds. Check config.baseURL and that the API is running.")
        case .failure(let error)?:
            let (code, advice) = describe(error)
            return SetupCheckResult(code: code, advice: advice)
        }
    }

    /// The session works, but the server refused the identity the app set.
    package static func result(forIdentity problem: IdentityProblem) -> SetupCheckResult {
        let advice =
            switch problem {
            case .userMismatch:
                "This install belongs to a different verified user. Call PingFront.shared.logout() before identify(token:) for another user."
            case .tokenInvalid: "The identity token signature did not verify. Sign it with the app's identity secret (HS256)."
            case .tokenExpired: "The identity token expired. Issue a fresh one with iat and an exp at most 24 h later."
            case .unknown: "The server refused the identity. Check the token and the user id."
            }
        return SetupCheckResult(code: "identity_\(problem.rawValue)", advice: advice)
    }

    package static func result(forKeyProblem problem: KeyProblem) -> SetupCheckResult {
        SetupCheckResult(code: "key_invalid", advice: problem.message)
    }

    static func describe(_ error: PingFrontError) -> (String, String) {
        switch error {
        case .invalidKey(let problem): return ("key_invalid", problem.message)
        case .network:
            return (
                "network",
                "The API could not be reached. Check the network and config.baseURL (the default is https://api.pingfront.sh/v1)."
            )
        case .coolingDown: return ("rate_limited", "Too many requests from this install. Wait a minute and run the check again.")
        case .server(let server):
            switch server.code {
            case .invalidAppKey:
                return (
                    "key_unknown",
                    "The server does not know this app key. Copy it again from Dashboard > App > Connect, and check test vs live."
                )
            case .appPaused: return ("app_paused", "The app is paused. Resume it in Dashboard > App > Settings.")
            case .blocked: return ("blocked", "This install is blocked in the dashboard. Unblock the person or use another device.")
            case .identityUserMismatch:
                return (
                    "identity_user_mismatch",
                    "This install belongs to a different verified user. Call PingFront.shared.logout() before identify(token:) for another user."
                )
            // Codes and our own advice only: the line is logged, and server text never goes in a log.
            default:
                return (
                    server.code.rawValue,
                    "The server answered \(server.status). See https://pingfront.sh/docs/errors#\(server.code.rawValue)."
                )
            }
        default: return ("unexpected", "The check failed unexpectedly. Run it again; if it keeps failing, see Dashboard > Health.")
        }
    }
}
