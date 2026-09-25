import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a model runs. Must be known *before* any processing starts.
public enum ProcessingLocation: String, Codable, Sendable, CaseIterable {
    /// Apple on-device frameworks / models on this iPhone or iPad.
    case device
    /// A Mac in the household (e.g. Ollama / LM Studio / MLX server on the LAN).
    case householdMac
    /// Home server / NAS inference endpoint controlled by the household.
    case householdServer
    /// A third-party provider. Data leaves the sovereign environment.
    case external

    public var leavesHousehold: Bool { self == .external }
}

public struct AIEndpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var location: ProcessingLocation
    /// OpenAI-compatible base URL (e.g. http://mac-studio.local:11434/v1). nil for on-device.
    public var baseURL: URL?
    public var model: String
    /// Provider organisation that will receive data (for external endpoints).
    public var provider: String?
    /// Keychain reference for an API key; never the key itself.
    public var credentialRef: String?

    public init(id: String = HearthIDs.new(), name: String, location: ProcessingLocation, baseURL: URL? = nil,
                model: String, provider: String? = nil, credentialRef: String? = nil) {
        self.id = id; self.name = name; self.location = location; self.baseURL = baseURL
        self.model = model; self.provider = provider; self.credentialRef = credentialRef
    }
}

/// One piece of household context offered to a model. Built by `ContextBuilder`, which
/// includes only what the task needs.
public struct ContextItem: Codable, Sendable, Hashable {
    public var recordID: String
    public var kind: RecordKind
    public var sensitivity: Sensitivity
    public var categories: [SensitiveCategory]
    public var text: String
    public var includesMedia: Bool
    public var includesDocument: Bool
    public var includesLocation: Bool
}

/// The disclosure classification attached to every AI request.
public struct DisclosureClassification: Codable, Sendable, Hashable {
    public var processingMode: ProcessingLocation
    public var destination: String
    public var provider: String?
    public var purpose: String
    public var mediaShared: Bool
    public var documentShared: Bool
    public var personalContextShared: Bool
    public var locationShared: Bool
    public var maxSensitivity: Sensitivity
    public var categories: [SensitiveCategory]
    public var recordIDs: [String]
    public var characterCount: Int

    /// "WHAT IS LEAVING / WHY / WHERE / WHO" for the approval sheet.
    public var summary: String {
        var what: [String] = []
        if personalContextShared { what.append("\(recordIDs.count) household record(s), \(characterCount) characters") }
        if mediaShared { what.append("photos/video") }
        if documentShared { what.append("documents") }
        if locationShared { what.append("location") }
        return """
        What is leaving: \(what.isEmpty ? "only your question" : what.joined(separator: ", "))
        Why: \(purpose)
        Where: \(destination)
        Provider: \(provider ?? "household-controlled")
        """
    }
}

public struct AIRequest: Sendable {
    public var purpose: String
    public var prompt: String
    public var endpoint: AIEndpoint
    public var context: [ContextItem]
    /// Media originals the user explicitly attached to this request.
    public var mediaIDs: [String]

    public init(purpose: String, prompt: String, endpoint: AIEndpoint, context: [ContextItem] = [], mediaIDs: [String] = []) {
        self.purpose = purpose; self.prompt = prompt; self.endpoint = endpoint; self.context = context; self.mediaIDs = mediaIDs
    }

    public var classification: DisclosureClassification {
        DisclosureClassification(
            processingMode: endpoint.location,
            destination: endpoint.baseURL?.host ?? endpoint.location.rawValue,
            provider: endpoint.provider,
            purpose: purpose,
            mediaShared: !mediaIDs.isEmpty || context.contains(where: \.includesMedia),
            documentShared: context.contains(where: \.includesDocument),
            personalContextShared: !context.isEmpty,
            locationShared: context.contains(where: \.includesLocation),
            maxSensitivity: context.map(\.sensitivity).max() ?? .normal,
            categories: Array(Set(context.flatMap(\.categories))).sorted { $0.rawValue < $1.rawValue },
            recordIDs: context.map(\.recordID),
            characterCount: context.reduce(prompt.count) { $0 + $1.text.count })
    }
}

public enum ApprovalChoice: String, Codable, Sendable {
    case allowOnce, allowForSource, deny
}

public enum PolicyDecision: Sendable {
    case allowed(AuthorizedAIRequest)
    case needsApproval(DisclosureClassification)
    case denied(String)
}

/// Proof that a request passed policy. Only `AIPolicyEngine` can create one, so a model
/// client cannot be called with un-evaluated data.
public struct AuthorizedAIRequest: Sendable {
    public let request: AIRequest
    public let classification: DisclosureClassification
    fileprivate init(_ request: AIRequest) { self.request = request; self.classification = request.classification }
}

public struct AIPolicySettings: Codable, Sendable {
    /// Master switch for any external provider. Off by default.
    public var externalAIEnabled = false
    /// Restricted (vault) records may never be sent externally unless this is on.
    public var allowRestrictedExternally = false
    /// Photos/video may never be sent externally unless this is on (still asks every time).
    public var allowMediaExternally = false
    public init() {}
}

public final class AIPolicyEngine: @unchecked Sendable {
    unowned let store: HearthStore
    public var settings: AIPolicySettings

    public init(store: HearthStore, settings: AIPolicySettings = AIPolicySettings()) {
        self.store = store; self.settings = settings
    }

    public func evaluate(_ request: AIRequest) throws -> PolicyDecision {
        let c = request.classification
        let granted = try hasGrant(endpointID: request.endpoint.id, purpose: request.purpose)
        let decision: PolicyDecision
        if !c.processingMode.leavesHousehold {
            decision = .allowed(AuthorizedAIRequest(request))
        } else if !settings.externalAIEnabled {
            decision = .denied("External AI is turned off. Use an on-device or household model, or enable external AI in Settings.")
        } else if c.maxSensitivity == .restricted && !settings.allowRestrictedExternally {
            decision = .denied("Restricted records (financial, identity, security...) are never sent to external providers.")
        } else if c.mediaShared && !settings.allowMediaExternally {
            decision = .denied("Sending photos or video to external providers is disabled.")
        } else if c.mediaShared || c.locationShared || c.maxSensitivity >= .private {
            decision = .needsApproval(c) // always ask for the most sensitive disclosures
        } else if !c.personalContextShared || granted {
            decision = .allowed(AuthorizedAIRequest(request))
        } else {
            decision = .needsApproval(c)
        }
        try audit(request, decision: decision)
        return decision
    }

    /// Applies the user's answer to an approval prompt.
    public func approve(_ request: AIRequest, choice: ApprovalChoice) throws -> AuthorizedAIRequest? {
        let decision: PolicyDecision
        switch choice {
        case .deny:
            decision = .denied("User denied")
        case .allowForSource:
            try store.db.execute("INSERT INTO ai_grants(grant_id, endpoint_id, purpose, created_at) VALUES (?, ?, ?, ?)",
                                 [.text(HearthIDs.new()), .text(request.endpoint.id), .text(request.purpose), .double(Date().timeIntervalSince1970)])
            decision = .allowed(AuthorizedAIRequest(request))
        case .allowOnce:
            decision = .allowed(AuthorizedAIRequest(request))
        }
        try audit(request, decision: decision)
        if case .allowed(let a) = decision { return a }
        return nil
    }

    public func revokeGrants(endpointID: String) throws {
        try store.db.execute("DELETE FROM ai_grants WHERE endpoint_id = ?", [.text(endpointID)])
    }

    private func hasGrant(endpointID: String, purpose: String) throws -> Bool {
        try !store.db.query("SELECT 1 FROM ai_grants WHERE endpoint_id = ? AND purpose = ?", [.text(endpointID), .text(purpose)]).isEmpty
    }

    /// Local audit log: which classification was requested and what was decided. No content.
    private func audit(_ request: AIRequest, decision: PolicyDecision) throws {
        let label: String
        switch decision {
        case .allowed: label = "allowed"
        case .needsApproval: label = "needs_approval"
        case .denied(let r): label = "denied: \(r)"
        }
        let json = String(decoding: try HearthJSON.encoder.encode(request.classification), as: UTF8.self)
        try store.db.execute("INSERT INTO ai_disclosures(disclosure_id, endpoint_id, purpose, classification, decision, at) VALUES (?, ?, ?, ?, ?, ?)",
                             [.text(HearthIDs.new()), .text(request.endpoint.id), .text(request.purpose), .text(json), .text(label),
                              .double(Date().timeIntervalSince1970)])
    }
}

/// Builds minimum-necessary context: only records matching the question, only readable
/// ones, never restricted records for external endpoints, location removed unless asked.
public enum ContextBuilder {
    public static func minimal(store: HearthStore, question: String, for endpoint: AIEndpoint,
                               limit: Int = 5, includeLocation: Bool = false) throws -> [ContextItem] {
        try store.search(question, limit: limit * 3).compactMap { hit -> ContextItem? in
            let env = hit.record
            if endpoint.location.leavesHousehold && env.sensitivity == .restricted { return nil }
            var fields = env.fields
            for k in ["acl", "sensitivity", "categories", "deleted", "emergency", "sha256"] { fields[k] = nil }
            let hadLocation = fields["location"] != nil && fields["location"] != .null
            if !includeLocation { fields["location"] = nil }
            let text = fields.sorted { $0.key < $1.key }
                .compactMap { k, v -> String? in
                    let t = v.searchableText.joined(separator: " ")
                    return t.isEmpty ? nil : "\(k): \(t)"
                }.joined(separator: "\n")
            return ContextItem(recordID: env.id, kind: env.kind, sensitivity: env.sensitivity, categories: env.categories,
                               text: text, includesMedia: false, includesDocument: env.kind == .media,
                               includesLocation: includeLocation && hadLocation)
        }
        .prefix(limit).map { $0 }
    }
}

/// Minimal client for OpenAI-compatible chat endpoints (Ollama, LM Studio, llama.cpp,
/// vLLM on a household server, or an external provider once approved).
public struct OpenAICompatibleClient: Sendable {
    public var credentials: CredentialStore
    public var session: URLSession = .shared

    public init(credentials: CredentialStore) { self.credentials = credentials }

    public func complete(_ authorized: AuthorizedAIRequest) async throws -> String {
        let r = authorized.request
        guard let base = r.endpoint.baseURL else { throw ConnectorError.misconfigured("endpoint has no base URL") }
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"), timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ref = r.endpoint.credentialRef, let key = try credentials.secret(for: ref) {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let context = r.context.map { "[\($0.kind.rawValue) \($0.recordID)]\n\($0.text)" }.joined(separator: "\n\n")
        let body: JSONValue = .object([
            "model": .string(r.endpoint.model),
            "messages": .array([
                .object(["role": .string("system"), "content": .string("You help a household use its own records. Use only the context provided. Context:\n\n" + context)]),
                .object(["role": .string("user"), "content": .string(r.prompt)]),
            ]),
        ])
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectorError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let choices)? = root["choices"], case .object(let first)? = choices.first,
              case .object(let message)? = first["message"], let content = message["content"]?.stringValue else {
            throw ConnectorError.badResponse("unexpected completion shape")
        }
        return content
    }
}

/// What on-device processing this hardware supports. Apple app fills this in by probing
/// Vision / Speech / Core ML; other platforms report what they can.
public enum ProcessingCapability: String, Codable, Sendable {
    case onDeviceAvailable, onDeviceDegraded, externalProcessingAvailable, processingDisabled
}

public struct CapabilityReport: Codable, Sendable {
    public var thumbnails: ProcessingCapability
    public var videoMetadata: ProcessingCapability
    public var keyframes: ProcessingCapability
    public var speechTranscription: ProcessingCapability
    public var textRecognition: ProcessingCapability
    public var imageClassification: ProcessingCapability
    public var searchEmbeddings: ProcessingCapability
    public init(thumbnails: ProcessingCapability, videoMetadata: ProcessingCapability, keyframes: ProcessingCapability,
                speechTranscription: ProcessingCapability, textRecognition: ProcessingCapability,
                imageClassification: ProcessingCapability, searchEmbeddings: ProcessingCapability) {
        self.thumbnails = thumbnails; self.videoMetadata = videoMetadata; self.keyframes = keyframes
        self.speechTranscription = speechTranscription; self.textRecognition = textRecognition
        self.imageClassification = imageClassification; self.searchEmbeddings = searchEmbeddings
    }
}
