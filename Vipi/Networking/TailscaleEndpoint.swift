import Foundation

struct TailscaleEndpoint: Equatable, Sendable {
    let publicURL: URL
    let webSocketURL: URL

    static func parse(_ value: String, allowsInsecureLocalhostForUITesting: Bool = false) throws -> Self {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let hostname = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw EndpointError.invalid
        }

        let isTailnetHTTPS = scheme == "https" && hostname.hasSuffix(".ts.net")
        #if DEBUG
        let isUITestLocalhost = allowsInsecureLocalhostForUITesting && scheme == "http" && hostname == "127.0.0.1"
        #else
        let isUITestLocalhost = false
        #endif
        guard isTailnetHTTPS || isUITestLocalhost else { throw EndpointError.insecure }

        components.path = ""
        guard let publicURL = components.url else { throw EndpointError.invalid }
        components.scheme = isTailnetHTTPS ? "wss" : "ws"
        components.path = "/ws"
        guard let webSocketURL = components.url else { throw EndpointError.invalid }
        return Self(publicURL: publicURL, webSocketURL: webSocketURL)
    }
}

enum EndpointError: LocalizedError {
    case invalid
    case insecure

    var errorDescription: String? {
        switch self {
        case .invalid:
            "Enter a host URL without credentials, query parameters, fragments, or paths."
        case .insecure:
            "Vipi requires an HTTPS .ts.net Tailscale host."
        }
    }
}
