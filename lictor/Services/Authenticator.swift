//
//  Authenticator.swift
//  lictor
//
//  Touch ID gate in front of enabling SSH.
//
//  Asymmetry is the point (principle 3): turning SSH **off** is one
//  click with no authentication, turning it **on** costs something. That makes it
//  structurally impossible to open SSH by misclicking, while never discouraging
//  anyone from closing it.
//
//  This is friction against the operator's own mistakes, not a security boundary.
//  Any process running as this user can already write RunSSH (see ADR-0001).
//

import Foundation
import LocalAuthentication

enum AuthenticationError: Error, CustomStringConvertible {
    case unavailable(String)
    case denied

    var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .denied:                  return "Authentication was cancelled"
        }
    }
}

enum Authenticator {

    /// Prompts for Touch ID, falling back to the login password.
    ///
    /// The fallback is deliberate: a wet or unrecognised finger must not be able
    /// to lock the user out of enabling SSH on their own machine.
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var probe: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &probe) else {
            throw AuthenticationError.unavailable(
                probe?.localizedDescription ?? "Authentication is unavailable")
        }

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
            guard ok else { throw AuthenticationError.denied }
        } catch let error as LAError where error.code == .userCancel
                                        || error.code == .appCancel
                                        || error.code == .systemCancel {
            throw AuthenticationError.denied
        }
    }
}
