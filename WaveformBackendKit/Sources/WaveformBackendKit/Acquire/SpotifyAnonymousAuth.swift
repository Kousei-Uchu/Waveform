//
//  SpotifyAnonymousAuth.swift
//  WaveformBackendKit
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


import Foundation
import CryptoKit

/// Obtains an anonymous ("guest") Spotify Web Player access token, the same
/// way open.spotify.com does for a logged-out visitor — no user login, no
/// developer Client ID/Secret.
///
/// **This is unofficial and inherently fragile.** Every value and endpoint
/// below was confirmed working end-to-end against Spotify's live servers
/// via a standalone Python script cross-checked directly against the
/// actual installed source of `Aran404/SpotAPI` (not just documentation) —
/// but Spotify rotates the underlying secret periodically and has changed
/// this scheme's shape multiple times historically. `secretConfigURL`
/// fetches the current secret at runtime rather than hardcoding it, so a
/// routine rotation self-heals without an app update — but if Spotify
/// changes the cipher shape itself (not just the bytes), this needs a
/// real code update.
public actor SpotifyAnonymousAuth {
    public static let shared = SpotifyAnonymousAuth()

    public struct GuestToken: Sendable {
        public let accessToken: String
        public let clientID: String?
        public let expiresAt: Date
    }

    public enum AuthError: Error, LocalizedError {
        case secretConfigUnavailable
        case tokenRequestFailed(Int)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .secretConfigUnavailable: "Couldn't fetch the current TOTP secret config."
            case .tokenRequestFailed(let code): "Token request failed (HTTP \(code))."
            case .malformedResponse: "Spotify's response didn't match the expected shape."
            }
        }
    }

    /// A JSON array of `{"version": Int, "secret": [Int]}` objects, newest
    /// not guaranteed to be last — `fetchSecretConfig()` picks the max
    /// version explicitly rather than assuming array order (this bit us
    /// once already: this exact file has historically listed entries
    /// newest-first).
    private let secretConfigURL = URL(string: "https://raw.githubusercontent.com/CycloneAddons/spotify-token-generator/main/secrets/secretsBytes.json")!

    private var cachedToken: GuestToken?

    private init() {}

    /// Returns a cached token if it hasn't expired yet, otherwise fetches
    /// a fresh one. Spotify's anonymous tokens are short-lived (roughly
    /// 45 minutes per observed responses) — callers doing repeated
    /// searches should hold onto this actor rather than re-authenticating
    /// per request.
    public func currentToken() async throws -> String {
        try await currentGuestToken().accessToken
    }

    /// Same as `currentToken()`, but also returns the `clientId` Spotify
    /// hands back in the same `/api/token` response — SpotAPI's
    /// `BaseClient._get_auth_vars()` reads `client_id` from this exact
    /// response (`resp.response["clientId"]`), not from anywhere else, so
    /// callers building the Web Player session (client-token request)
    /// should use this rather than trying to recover client ID from the
    /// homepage's `appServerConfig` blob, which doesn't reliably carry it.
    public func currentGuestToken() async throws -> GuestToken {
        if let cachedToken, cachedToken.expiresAt > Date().addingTimeInterval(30) {
            return cachedToken
        }
        let token = try await fetchNewToken()
        cachedToken = token
        return token
    }

    // MARK: - Private

    private struct SecretEntry: Decodable {
        let version: Int
        let secret: [Int]
    }

    private func fetchNewToken() async throws -> GuestToken {
        let (version, secretInts) = try await fetchSecretConfig()
        let totp = generateTOTP(secretInts: secretInts)

        // Confirmed-working shape: reason=init (not "transport" — that's
        // the now-dead /get_access_token endpoint's param), totpServer
        // duplicates the same code (not a second, server-time-based
        // computation), and no sTime/cTime at all.
        var components = URLComponents(string: "https://open.spotify.com/api/token")!
        components.queryItems = [
            URLQueryItem(name: "reason", value: "init"),
            URLQueryItem(name: "productType", value: "web-player"),
            URLQueryItem(name: "totp", value: totp),
            URLQueryItem(name: "totpVer", value: String(version)),
            URLQueryItem(name: "totpServer", value: totp)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.tokenRequestFailed(code)
        }

        struct TokenResponse: Decodable {
            let accessToken: String
            let clientId: String?
            let accessTokenExpirationTimestampMs: Int64
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.malformedResponse
        }

        let expiresAt = Date(timeIntervalSince1970: Double(decoded.accessTokenExpirationTimestampMs) / 1000)
        return GuestToken(accessToken: decoded.accessToken, clientID: decoded.clientId, expiresAt: expiresAt)
    }

    private func fetchSecretConfig() async throws -> (version: Int, secret: [Int]) {
        let (data, response) = try await URLSession.shared.data(from: secretConfigURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let entries = try? JSONDecoder().decode([SecretEntry].self, from: data),
              let newest = entries.max(by: { $0.version < $1.version }) else {
            throw AuthError.secretConfigUnavailable
        }
        return (newest.version, newest.secret)
    }

    /// Matches `Aran404/SpotAPI`'s `generate_totp()` exactly, confirmed
    /// working end-to-end:
    /// 1. XOR each secret byte with `(index % 33) + 9`.
    /// 2. Join the results as a decimal-digit string, UTF-8-encode it,
    ///    hex-encode those bytes into a hex *string*.
    /// 3. **Decode that hex string back into real bytes** (this was the
    ///    actual bug in an earlier version of this file — it re-encoded
    ///    the hex string's own ASCII characters instead of decoding the
    ///    hex back to bytes, silently producing a completely wrong,
    ///    double-length key).
    /// 4. Base32-encode those bytes as the HOTP/TOTP secret.
    /// 5. Standard TOTP: HMAC-SHA1, 30-second step, using the *local
    ///    device clock* — not a fetched server time. The reference
    ///    implementation (`pyotp.TOTP(secret).now()`) uses local time too;
    ///    a synced clock lands in the same 30-second window regardless.
    private func generateTOTP(secretInts: [Int]) -> String {
        let transformed = secretInts.enumerated().map { index, byte in
            byte ^ ((index % 33) + 9)
        }
        let digitString = transformed.map(String.init).joined()
        let hexString = digitString.utf8.map { String(format: "%02x", $0) }.joined()
        let secretData = Data(hexDecoding: hexString) // real bytes, not the hex text's own UTF-8 bytes
        let base32Secret = base32Encode(secretData)

        let counter = UInt64(Date().timeIntervalSince1970) / 30
        return hotp(base32Secret: base32Secret, counter: counter)
    }

    private func hotp(base32Secret: String, counter: UInt64) -> String {
        guard let keyData = base32Decode(base32Secret) else { return "" }

        var counterBigEndian = counter.bigEndian
        let counterData = Data(bytes: &counterBigEndian, count: 8)

        let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: SymmetricKey(data: keyData))
        let hmacBytes = Array(hmac)

        let offset = Int(hmacBytes[hmacBytes.count - 1] & 0x0f)
        let truncated = (UInt32(hmacBytes[offset] & 0x7f) << 24)
            | (UInt32(hmacBytes[offset + 1]) << 16)
            | (UInt32(hmacBytes[offset + 2]) << 8)
            | UInt32(hmacBytes[offset + 3])

        let code = truncated % 1_000_000
        return String(format: "%06d", code)
    }

    // MARK: - Base32 (RFC 4648, no padding)

    private func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var result = ""
        var bits = 0
        var value = 0
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                result.append(alphabet[(value >> (bits - 5)) & 0x1F])
                bits -= 5
            }
        }
        if bits > 0 {
            result.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        return result
    }

    private func base32Decode(_ string: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0
        var value = 0
        var output = Data()
        for char in string.uppercased() {
            guard let index = alphabet.firstIndex(of: char) else { continue }
            value = (value << 5) | alphabet.distance(from: alphabet.startIndex, to: index)
            bits += 5
            if bits >= 8 {
                output.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return output
    }
}

private extension Data {
    /// Decodes a hex string into the raw bytes it represents — e.g.
    /// "377a" -> [0x37, 0x7a]. Not to be confused with UTF-8-encoding the
    /// hex string's own characters, which is the bug this replaced.
    init(hexDecoding hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        self = data
    }
}
