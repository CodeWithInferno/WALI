import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

@MainActor
public final class AppleSignInCoordinator: NSObject {
    private let sessionStore: AuthSessionStore
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var authorizationController: ASAuthorizationController?
    private weak var presentationAnchor: NSWindow?
    private var rawNonce: String?

    public init(sessionStore: AuthSessionStore) {
        self.sessionStore = sessionStore
    }

    public func signIn(presentingFrom window: NSWindow) async throws -> CatalogAuthState {
        guard continuation == nil else { throw CatalogRequestError.invalidRequest }
        let nonce = try Self.makeNonce()
        rawNonce = nonce
        presentationAnchor = window

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        authorizationController = controller

        let credentials = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
        return try await sessionStore.signInWithApple(
            idToken: credentials.0,
            nonce: credentials.1
        )
    }

    private func finish(_ result: Result<(String, String), Error>) {
        let pending = continuation
        continuation = nil
        authorizationController = nil
        presentationAnchor = nil
        rawNonce = nil
        pending?.resume(with: result)
    }

    private static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CatalogRemoteError(
                code: "secure_random_unavailable",
                safeMessage: nil,
                retryable: true
            )
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken,
              let idToken = String(data: token, encoding: .utf8),
              let rawNonce
        else {
            finish(.failure(CatalogRemoteError(
                code: "authentication_failed",
                safeMessage: nil,
                retryable: false
            )))
            return
        }
        finish(.success((idToken, rawNonce)))
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        finish(.failure(CatalogRemoteError(
            code: "authentication_failed",
            safeMessage: nil,
            retryable: false
        )))
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presentationAnchor ?? NSApplication.shared.keyWindow ?? NSWindow()
    }
}
