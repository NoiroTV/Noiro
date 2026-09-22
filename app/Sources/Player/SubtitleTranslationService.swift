#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import os.log

/// Gemini AI subtitle translation — a port of Vortexo's `EmbeddedSubtitleTranslationService`.
/// Translates subtitle cue text to a target language via Google's Generative Language REST API.
/// Self-contained value work: no SwiftUI, no player references. The player layer feeds cues in and
/// reads translated text back; everything else (model fallback, rate limiting, caching) lives here.
///
/// The user supplies a Gemini API key (Settings → Audio & Subtitles); without it the service is a no-op
/// and the original subtitle shows unchanged, so playback is never left without subtitles.

// MARK: - Cue

/// One subtitle cue for translation: a stable id (the cue's index in the source track) + its text.
/// Codable so it round-trips through Gemini's batch JSON contract ({id, text}).
struct SubtitleTranslationCue: Codable, Equatable, Sendable {
    let id: Int
    let text: String
}

// MARK: - Presentation policy

/// Decides what to show given an original + a (possibly pending) translation. Returns "" when the
/// translation is missing/empty/identical to the original — the caller then falls back to the original.
enum SubtitleTranslationPresentationPolicy {
    static func displayedText(originalText: String, translatedText: String?) -> String {
        guard let translatedText else { return "" }
        let cleanedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedOriginal = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranslation.isEmpty, cleanedTranslation != cleanedOriginal else { return "" }

        // Gemini occasionally keeps the source cue as a separate line despite being asked for target-only
        // output. Never present that retained block beside the translation. Exact-line removal is deliberately
        // conservative: names or words that merely occur inside a translated sentence are preserved.
        let originalLines = Set(cleanedOriginal.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let translationLines = cleanedTranslation.components(separatedBy: .newlines)
        let targetOnlyLines = translationLines.filter {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty || !originalLines.contains(line)
        }
        let targetOnly = targetOnlyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return targetOnly.isEmpty ? "" : targetOnly
    }
}

// MARK: - Model catalog + fallback

/// The Gemini models tried in order. Flash-Lite variants come first for subtitle latency/cost. The current
/// full Flash model and still-supported 2.5 Flash-Lite remain fallbacks because user-owned AI Studio projects
/// can have model-specific free-tier availability; one model returning 429 does not prove every tier is empty.
enum SubtitleTranslationModelCatalog {
    nonisolated static let gemini = [
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash-lite",
        "gemini-3.6-flash",
        "gemini-3.5-flash"
    ]
}

enum SubtitleTranslationModelFallbackDecision: Sendable {
    case tryNextModel(rateLimited: Bool)
    case stop
}

enum SubtitleTranslationModelFallbackPolicy {
    nonisolated static func decision(afterHTTPStatus statusCode: Int) -> SubtitleTranslationModelFallbackDecision {
        switch statusCode {
        case 429:                              // rate limited → quarantine this model; caller pauses before fallback
            return .tryNextModel(rateLimited: true)
        case 400, 404, 408, 500, 502, 503, 504: // transient/server → try the next model
            return .tryNextModel(rateLimited: false)
        default:                               // 401/403 (bad key) etc. → stop, no point cycling models
            return .stop
        }
    }

    nonisolated static func exhaustedModelsCooldown(
        sawRateLimit: Bool,
        rateLimitCooldown: TimeInterval,
        temporaryFailureCooldown: TimeInterval
    ) -> TimeInterval {
        sawRateLimit ? rateLimitCooldown : temporaryFailureCooldown
    }
}

/// Per-model health: tracks when each model becomes available again after a failure, with exponential
/// backoff, and keeps a sticky "preferred" model (the last one that succeeded) tried first.
enum SubtitleTranslationModelHealthPolicy {
    nonisolated static func orderedAvailableModels(
        configuredModels: [String],
        preferredModel: String?,
        unavailableUntil: [String: Date],
        now: Date
    ) -> [String] {
        let available = configuredModels.filter { model in
            guard let retryAt = unavailableUntil[model] else { return true }
            return retryAt <= now
        }
        guard let preferredModel, available.contains(preferredModel) else { return available }
        return [preferredModel] + available.filter { $0 != preferredModel }
    }

    nonisolated static func nextAvailability(
        configuredModels: [String],
        unavailableUntil: [String: Date],
        now: Date
    ) -> Date? {
        configuredModels.compactMap { model in
            guard let retryAt = unavailableUntil[model], retryAt > now else { return nil }
            return retryAt
        }
        .min()
    }

    nonisolated static func exponentialBackoff(
        failureCount: Int,
        baseDelay: TimeInterval,
        maximumDelay: TimeInterval = 300
    ) -> TimeInterval {
        guard baseDelay > 0, maximumDelay > 0 else { return 0 }
        let exponent = max(0, min(failureCount - 1, 4))
        return min(baseDelay * pow(2, Double(exponent)), maximumDelay)
    }
}

// MARK: - Batch mapping policy

/// Maps Gemini's batch response back onto the requested cue ids. Gemini can renumber ids from zero or
/// return a partial array; this tolerates all three cases (exact-id match → positional zip → partial-id).
enum SubtitleTranslationBatchMappingPolicy {
    nonisolated static func translations(
        requestedCues: [SubtitleTranslationCue],
        returnedCues: [SubtitleTranslationCue]
    ) -> [Int: String] {
        let requestedIDs = Set(requestedCues.map(\.id))
        let returnedIDs = Set(returnedCues.map(\.id))

        if requestedIDs == returnedIDs {
            return returnedCues.reduce(into: [:]) { result, cue in
                let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result[cue.id] = text }
            }
        }

        // Same count, different ids → trust the model's order, attach to the requested timeline ids.
        if requestedCues.count == returnedCues.count {
            return zip(requestedCues, returnedCues).reduce(into: [:]) { result, pair in
                let text = pair.1.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result[pair.0.id] = text }
            }
        }

        // Partial → accept only ids that provably match.
        return returnedCues.reduce(into: [:]) { result, cue in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if requestedIDs.contains(cue.id), !text.isEmpty { result[cue.id] = text }
        }
    }
}

// MARK: - Request gate

/// Serializes requests so only one is in flight at a time, with a minimum spacing after each release
/// to stay under Gemini's per-minute burst limit.
actor SubtitleTranslationRequestGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }
        // Cancellation-safe: if the task is cancelled while waiting in the queue, don't block forever.
        // The previous version could deadlock if a waiting task was cancelled before release() was called,
        // leaving isRunning=true and no waiter ever resumed.
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Force-release the gate (clear any stuck state). Called when starting a fresh translation session
    /// to recover from a prior deadlock where a cancelled task left the gate locked.
    func forceReset() {
        isRunning = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func release(minimumIntervalNanoseconds: UInt64) async {
        if minimumIntervalNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: minimumIntervalNanoseconds)
        }
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }
        waiters.removeFirst().resume()
    }
}

// MARK: - Service

/// The Gemini translation service. Single-tenant: one in-flight request at a time (via the gate),
/// adaptive per-batch spacing, model fallback with exponential backoff, and a sticky preferred model.
/// Reads the API key from `ApiKeys.geminiKey()` (Keychain-backed); without it, every call is a no-op.
actor SubtitleTranslationService {
    static let shared = SubtitleTranslationService()

    private static let logger = Logger(subsystem: "app.noiro", category: "SubtitleTranslation")
    private static let geminiModels = SubtitleTranslationModelCatalog.gemini

    // Per-request spacing that scales with batch size: a 1-cue live batch needs to land before the cue
    // scrolls off, while a 60-cue whole-track batch can be paced conservatively. Five large requests per
    // minute keeps a long film from gradually walking into Gemini's RPM/TPM ceiling.
    private static let fullBatchRequestIntervalNs: UInt64 = 12_000_000_000
    private static let liveBatchRequestIntervalNs: UInt64 = 6_000_000_000
    private static let singleCueRequestIntervalNs: UInt64 = 1_200_000_000
    private static let rateLimitCooldown: TimeInterval = 90
    private static let temporaryFailureCooldown: TimeInterval = 30

    private static func requestIntervalNs(forCueCount count: Int) -> UInt64 {
        guard count > 1 else { return singleCueRequestIntervalNs }
        if count <= 10 {
            let fraction = Double(count - 1) / 9.0
            let start = Double(singleCueRequestIntervalNs)
            let end = Double(liveBatchRequestIntervalNs)
            return UInt64(start + (end - start) * fraction)
        }
        let fraction = Double(min(count, 60) - 10) / 50.0
        let start = Double(liveBatchRequestIntervalNs)
        let end = Double(fullBatchRequestIntervalNs)
        return UInt64(start + (end - start) * fraction)
    }

    // MARK: Gemini REST models

    private struct GeminiRequest: Encodable {
        let contents: [GeminiContent]
        let generationConfig: GeminiGenerationConfig
    }
    private struct GeminiContent: Encodable { let role: String; let parts: [GeminiPart] }
    private struct GeminiPart: Encodable { let text: String }
    private struct GeminiGenerationConfig: Encodable {
        let maxOutputTokens: Int
        let responseMimeType: String?
    }
    private struct GeminiResponse: Decodable { let candidates: [GeminiCandidate]? }
    private struct GeminiCandidate: Decodable { let content: GeminiResponseContent? }
    private struct GeminiResponseContent: Decodable { let parts: [GeminiResponsePart]? }
    private struct GeminiResponsePart: Decodable { let text: String? }
    private struct GeminiBatchWrapper: Decodable {
        let cues: [SubtitleTranslationCue]?
        let translations: [SubtitleTranslationCue]?
    }
    private struct GeminiErrorEnvelope: Decodable {
        let error: GeminiErrorBody?
    }
    private struct GeminiErrorBody: Decodable {
        let message: String?
        let status: String?
        let details: [GeminiErrorDetail]?
    }
    private struct GeminiErrorDetail: Decodable {
        let type: String?
        let retryDelay: String?
        let violations: [GeminiQuotaViolation]?

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case retryDelay
            case violations
        }
    }
    private struct GeminiQuotaViolation: Decodable {
        let quotaMetric: String?
        let quotaId: String?
    }
    private struct GeminiFailureMetadata {
        let category: String
        let retryDelay: TimeInterval?
        let quotaName: String?
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session: URLSession
    private var unavailableUntil: Date?                 // global cooldown (bad key / all models exhausted)
    private let requestGate = SubtitleTranslationRequestGate()
    private var preferredGeminiModel: String?
    private var modelUnavailableUntil: [String: Date] = [:]
    private var modelFailureCounts: [String: Int] = [:]
    private var hasLoggedMissingGeminiKey = false
    private var activeAPIKey: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Single cue

    func translate(text: String, sourceLanguage: String?, targetLanguage: String) async -> String? {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTarget = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty, !cleanedTarget.isEmpty else { return nil }

        guard let apiKey = ApiKeys.geminiKey() else {
            if !hasLoggedMissingGeminiKey {
                hasLoggedMissingGeminiKey = true
                Self.logger.warning("Gemini subtitle translation skipped: missing user API key")
            }
            return nil
        }
        hasLoggedMissingGeminiKey = false
        resetCooldownsIfCredentialChanged(apiKey)
        if let unavailableUntil, Date() < unavailableUntil { return nil }

        await requestGate.acquire()
        defer {
            Task { await requestGate.release(minimumIntervalNanoseconds: Self.singleCueRequestIntervalNs) }
        }
        guard !Task.isCancelled else { return nil }
        if let unavailableUntil, Date() < unavailableUntil { return nil }

        return await performTranslationRequest(
            cleanedText: cleanedText, sourceLanguage: sourceLanguage,
            cleanedTarget: cleanedTarget, apiKey: apiKey
        )
    }

    /// Direct single-cue translation WITHOUT the serial request gate. Used by the embedded-cue live
    /// translator where each cue is independent and the gate can deadlock if a task is cancelled mid-flight.
    /// Respects model health + cooldowns but does NOT serialize (so concurrent cues can overlap).
    func translateDirect(text: String, sourceLanguage: String?, targetLanguage: String) async -> String? {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTarget = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty, !cleanedTarget.isEmpty else { return nil }

        guard let apiKey = ApiKeys.geminiKey() else { return nil }
        resetCooldownsIfCredentialChanged(apiKey)
        if let unavailableUntil, Date() < unavailableUntil { return nil }

        return await performTranslationRequest(
            cleanedText: cleanedText, sourceLanguage: sourceLanguage,
            cleanedTarget: cleanedTarget, apiKey: apiKey
        )
    }

    /// Shared request logic for both gated (translate) and ungated (translateDirect) paths.
    private func performTranslationRequest(
        cleanedText: String, sourceLanguage: String?, cleanedTarget: String, apiKey: String
    ) async -> String? {
        guard let body = try? encoder.encode(
            Self.geminiRequest(text: cleanedText, sourceLanguage: sourceLanguage, targetLanguage: cleanedTarget)
        ) else { return nil }

        let availableModels = availableGeminiModels(at: Date())
        guard !availableModels.isEmpty else {
            unavailableUntil = nextGeminiModelAvailability(after: Date())
            return nil
        }

        var sawRateLimit = false
        for model in availableModels {
            guard !Task.isCancelled else { return nil }
            do {
                let request = Self.geminiURLRequest(model: model, apiKey: apiKey, timeout: 12, body: body)
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }

                guard (200..<300).contains(http.statusCode) else {
                    let failure = Self.failureMetadata(data: data, response: http)
                    Self.logger.warning("Gemini subtitle translation failed model=\(model, privacy: .public) status=\(http.statusCode, privacy: .public) reason=\(failure.category, privacy: .public) retry=\(failure.retryDelay ?? 0, privacy: .public)s")
                    switch SubtitleTranslationModelFallbackPolicy.decision(afterHTTPStatus: http.statusCode) {
                    case .tryNextModel(let rateLimited):
                        sawRateLimit = sawRateLimit || rateLimited
                        let retryAt = recordGeminiModelFailure(
                            model, rateLimited: rateLimited,
                            minimumDelay: failure.retryDelay
                        )
                        // A daily quota is model-specific: quarantine that model until its reset and give the
                        // next configured model one chance. A short RPM/TPM 429 can apply across the project,
                        // so pause the whole pass instead of multiplying one cue into a request burst.
                        if rateLimited {
                            if failure.category == "daily-quota" { continue }
                            unavailableUntil = retryAt
                            return nil
                        }
                        continue
                    case .stop:
                        unavailableUntil = Date().addingTimeInterval(45)
                        return nil
                    }
                }

                let decoded = try decoder.decode(GeminiResponse.self, from: data)
                let translated = decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let translated, !translated.isEmpty, translated != cleanedText else { return nil }
                recordGeminiModelSuccess(model)
                return translated
            } catch {
                Self.logger.warning("Gemini subtitle translation request failed model=\(model, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                if Self.shouldTryNextModel(after: error) {
                    recordGeminiModelFailure(model, rateLimited: false)
                    continue
                }
                unavailableUntil = Date().addingTimeInterval(30)
                return nil
            }
        }

        unavailableUntil = nextGeminiModelAvailability(after: Date())
            ?? Date().addingTimeInterval(SubtitleTranslationModelFallbackPolicy.exhaustedModelsCooldown(
                sawRateLimit: sawRateLimit,
                rateLimitCooldown: Self.rateLimitCooldown,
                temporaryFailureCooldown: Self.temporaryFailureCooldown
            ))
        return nil
    }

    // MARK: Batch

    func translateBatch(
        cues: [SubtitleTranslationCue],
        sourceLanguage: String?,
        targetLanguage: String
    ) async -> [Int: String] {
        let cleanedCues = cues.compactMap { cue -> SubtitleTranslationCue? in
            let cleaned = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : SubtitleTranslationCue(id: cue.id, text: cleaned)
        }
        let cleanedTarget = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCues.isEmpty, !cleanedTarget.isEmpty else { return [:] }

        guard let apiKey = ApiKeys.geminiKey() else {
            if !hasLoggedMissingGeminiKey {
                hasLoggedMissingGeminiKey = true
                Self.logger.warning("Gemini subtitle batch translation skipped: missing user API key")
            }
            return [:]
        }
        hasLoggedMissingGeminiKey = false
        resetCooldownsIfCredentialChanged(apiKey)
        if let unavailableUntil, Date() < unavailableUntil { return [:] }

        await requestGate.acquire()
        var didPerformRequest = false
        defer {
            let interval = didPerformRequest ? Self.requestIntervalNs(forCueCount: cues.count) : 0
            Task { await requestGate.release(minimumIntervalNanoseconds: interval) }
        }
        guard !Task.isCancelled else { return [:] }
        if let unavailableUntil, Date() < unavailableUntil { return [:] }

        guard let body = try? encoder.encode(
            Self.geminiBatchRequest(cues: cleanedCues, sourceLanguage: sourceLanguage, targetLanguage: cleanedTarget)
        ) else { return [:] }

        let availableModels = availableGeminiModels(at: Date())
        guard !availableModels.isEmpty else {
            unavailableUntil = nextGeminiModelAvailability(after: Date())
            return [:]
        }

        var sawRateLimit = false
        for model in availableModels {
            guard !Task.isCancelled else { return [:] }
            do {
                // Whole-track translation can produce tens of thousands of output tokens. Give the
                // response time to complete instead of turning a healthy long request into a timeout.
                let request = Self.geminiURLRequest(model: model, apiKey: apiKey, timeout: 120, body: body)
                didPerformRequest = true
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }

                guard (200..<300).contains(http.statusCode) else {
                    let failure = Self.failureMetadata(data: data, response: http)
                    Self.logger.warning("Gemini subtitle batch translation failed model=\(model, privacy: .public) status=\(http.statusCode, privacy: .public) reason=\(failure.category, privacy: .public) quota=\(failure.quotaName ?? "unknown", privacy: .public) retry=\(failure.retryDelay ?? 0, privacy: .public)s")
                    switch SubtitleTranslationModelFallbackPolicy.decision(afterHTTPStatus: http.statusCode) {
                    case .tryNextModel(let rateLimited):
                        sawRateLimit = sawRateLimit || rateLimited
                        let retryAt = recordGeminiModelFailure(
                            model, rateLimited: rateLimited,
                            minimumDelay: failure.retryDelay
                        )
                        if rateLimited {
                            if failure.category == "daily-quota" { continue }
                            unavailableUntil = retryAt
                            return [:]
                        }
                        continue
                    case .stop:
                        unavailableUntil = Date().addingTimeInterval(45)
                        return [:]
                    }
                }

                let decoded = try decoder.decode(GeminiResponse.self, from: data)
                let payload = decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let payload,
                      let translated = Self.decodeBatchTranslationPayload(payload, decoder: decoder),
                      !translated.isEmpty else { return [:] }
                let mapped = SubtitleTranslationBatchMappingPolicy.translations(requestedCues: cleanedCues, returnedCues: translated)
                guard !mapped.isEmpty else { return [:] }
                recordGeminiModelSuccess(model)
                return mapped
            } catch {
                Self.logger.warning("Gemini subtitle batch translation request failed model=\(model, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                if Self.shouldTryNextModel(after: error) {
                    recordGeminiModelFailure(model, rateLimited: false)
                    continue
                }
                unavailableUntil = Date().addingTimeInterval(30)
                return [:]
            }
        }

        unavailableUntil = nextGeminiModelAvailability(after: Date())
            ?? Date().addingTimeInterval(SubtitleTranslationModelFallbackPolicy.exhaustedModelsCooldown(
                sawRateLimit: sawRateLimit,
                rateLimitCooldown: Self.rateLimitCooldown,
                temporaryFailureCooldown: Self.temporaryFailureCooldown
            ))
        return [:]
    }

    /// Delay before a full-track pass retries after a failed/empty chunk. At least 5s; otherwise waits
    /// for the next model to become available.
    func retryDelayAfterFailure(now: Date = Date()) -> TimeInterval {
        let candidates = [unavailableUntil, nextGeminiModelAvailability(after: now)]
            .compactMap { $0 }
            .filter { $0 > now }
        guard let retryAt = candidates.min() else { return 5 }
        return max(5, retryAt.timeIntervalSince(now))
    }

    // MARK: Model health

    private func availableGeminiModels(at now: Date) -> [String] {
        SubtitleTranslationModelHealthPolicy.orderedAvailableModels(
            configuredModels: Self.geminiModels,
            preferredModel: preferredGeminiModel,
            unavailableUntil: modelUnavailableUntil,
            now: now
        )
    }

    private func nextGeminiModelAvailability(after now: Date) -> Date? {
        SubtitleTranslationModelHealthPolicy.nextAvailability(
            configuredModels: Self.geminiModels,
            unavailableUntil: modelUnavailableUntil,
            now: now
        )
    }

    private func recordGeminiModelSuccess(_ model: String) {
        preferredGeminiModel = model
        modelUnavailableUntil.removeValue(forKey: model)
        modelFailureCounts.removeValue(forKey: model)
        unavailableUntil = nil
    }

    @discardableResult
    private func recordGeminiModelFailure(
        _ model: String,
        rateLimited: Bool,
        minimumDelay: TimeInterval? = nil
    ) -> Date {
        let failureCount = (modelFailureCounts[model] ?? 0) + 1
        modelFailureCounts[model] = failureCount
        if preferredGeminiModel == model { preferredGeminiModel = nil }

        let baseDelay = rateLimited ? Self.rateLimitCooldown : Self.temporaryFailureCooldown
        let backoff = SubtitleTranslationModelHealthPolicy.exponentialBackoff(failureCount: failureCount, baseDelay: baseDelay)
        let delay = max(backoff, minimumDelay ?? 0)
        let jitter = Double.random(in: 0...min(5, delay * 0.1))
        let retryAt = Date().addingTimeInterval(delay + jitter)
        modelUnavailableUntil[model] = retryAt
        return retryAt
    }

    private func resetCooldownsIfCredentialChanged(_ apiKey: String) {
        guard activeAPIKey != apiKey else { return }
        activeAPIKey = apiKey
        unavailableUntil = nil
        preferredGeminiModel = nil
        modelUnavailableUntil.removeAll()
        modelFailureCounts.removeAll()
    }

    private static func failureMetadata(data: Data, response: HTTPURLResponse) -> GeminiFailureMetadata {
        let decoded = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data).error
        let details = decoded?.details ?? []
        let quotaText = details.flatMap { detail in
            (detail.violations ?? []).flatMap { [$0.quotaMetric, $0.quotaId].compactMap { $0 } }
        }.joined(separator: " ").lowercased()
        let message = decoded?.message?.lowercased() ?? ""
        let status = decoded?.status?.lowercased() ?? ""

        let category: String
        if quotaText.contains("perday") || quotaText.contains("per_day")
            || quotaText.contains("daily") || message.contains("daily quota") {
            category = "daily-quota"
        } else if response.statusCode == 429 || status == "resource_exhausted" {
            category = "rate-limit"
        } else if !status.isEmpty {
            category = status
        } else {
            category = "http-\(response.statusCode)"
        }

        let bodyDelay = details.compactMap { parseRetryDuration($0.retryDelay) }.max()
        let headerDelay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let retryDelay: TimeInterval?
        if category == "daily-quota" {
            retryDelay = max(bodyDelay ?? 0, secondsUntilGeminiDailyReset())
        } else {
            retryDelay = [bodyDelay, headerDelay].compactMap { $0 }.max()
        }
        let quotaName = details.lazy.compactMap { detail in
            detail.violations?.first.flatMap { $0.quotaId ?? $0.quotaMetric }
        }.first
        return GeminiFailureMetadata(category: category, retryDelay: retryDelay, quotaName: quotaName)
    }

    private static func parseRetryDuration(_ rawValue: String?) -> TimeInterval? {
        guard let rawValue else { return nil }
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.hasSuffix("s"), let seconds = TimeInterval(cleaned.dropLast()) else { return nil }
        return max(0, seconds)
    }

    private static func secondsUntilGeminiDailyReset(now: Date = Date()) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let start = calendar.startOfDay(for: now)
        let nextReset = calendar.date(byAdding: .day, value: 1, to: start)
            ?? now.addingTimeInterval(24 * 60 * 60)
        return max(Self.rateLimitCooldown, nextReset.timeIntervalSince(now) + 60)
    }

    private static func shouldTryNextModel(after error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return true }
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .badServerResponse:
            return true
        default:
            return false
        }
    }

    // MARK: Request building

    private static func geminiURLRequest(model: String, apiKey: String, timeout: TimeInterval, body: Data) -> URLRequest {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body
        return request
    }

    private static func geminiRequest(text: String, sourceLanguage: String?, targetLanguage: String) -> GeminiRequest {
        let source = cleanedSourceLanguage(sourceLanguage)
        let prompt = """
        Translate this subtitle text to \(targetLanguageName(targetLanguage)).
        Return only the translated subtitle text.
        Do not explain, summarize, transliterate, or keep the source language unless the target language is the same.
        Preserve line breaks, punctuation, names, speaker labels, and simple formatting.
        Source language: \(source).

        \(text)
        """
        return GeminiRequest(
            contents: [GeminiContent(role: "user", parts: [GeminiPart(text: prompt)])],
            generationConfig: GeminiGenerationConfig(maxOutputTokens: 512, responseMimeType: nil)
        )
    }

    private static func geminiBatchRequest(
        cues: [SubtitleTranslationCue],
        sourceLanguage: String?,
        targetLanguage: String
    ) throws -> GeminiRequest {
        let source = cleanedSourceLanguage(sourceLanguage)
        let inputData = try JSONEncoder().encode(cues)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "[]"
        let prompt = """
        Translate each subtitle cue text to \(targetLanguageName(targetLanguage)).
        Return valid JSON only.
        Keep the same array length, order, and id values.
        Return an array of objects with exactly these fields: id, text.
        Preserve names, punctuation, speaker labels, and line breaks inside text.
        Source language: \(source).

        Input:
        \(inputJSON)
        """
        return GeminiRequest(
            contents: [GeminiContent(role: "user", parts: [GeminiPart(text: prompt)])],
            generationConfig: GeminiGenerationConfig(
                // Current Flash/Flash-Lite models support 65,536 output tokens. A full subtitle track
                // normally needs far less, but the larger ceiling prevents valid whole-track JSON from
                // being truncated at the previous 8K cap.
                maxOutputTokens: 65_536,
                responseMimeType: "application/json"
            )
        )
    }

    private static func decodeBatchTranslationPayload(_ payload: String, decoder: JSONDecoder) -> [SubtitleTranslationCue]? {
        guard let data = cleanedJSONPayload(payload).data(using: .utf8) else { return nil }
        if let cues = try? decoder.decode([SubtitleTranslationCue].self, from: data) { return cues }
        if let wrapper = try? decoder.decode(GeminiBatchWrapper.self, from: data) { return wrapper.cues ?? wrapper.translations }
        return nil
    }

    /// Strip a ```json fenced block if Gemini wrapped the JSON in markdown despite the mime type.
    private static func cleanedJSONPayload(_ payload: String) -> String {
        var cleaned = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func cleanedSourceLanguage(_ language: String?) -> String {
        let cleaned = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "auto" : cleaned
    }

    /// ISO code → English language name, injected into the prompt. Ported verbatim from Vortexo.
    private static func targetLanguageName(_ code: String) -> String {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sq": return "Albanian"
        case "ar": return "Arabic"
        case "bs": return "Bosnian"
        case "bg": return "Bulgarian"
        case "zh": return "Chinese"
        case "hr": return "Croatian"
        case "cs": return "Czech"
        case "da": return "Danish"
        case "nl": return "Dutch"
        case "en": return "English"
        case "et": return "Estonian"
        case "fi": return "Finnish"
        case "fr": return "French"
        case "de": return "German"
        case "el": return "Greek"
        case "he": return "Hebrew"
        case "hi": return "Hindi"
        case "hu": return "Hungarian"
        case "id": return "Indonesian"
        case "it": return "Italian"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "lv": return "Latvian"
        case "lt": return "Lithuanian"
        case "mk": return "Macedonian"
        case "no": return "Norwegian"
        case "pl": return "Polish"
        case "pt": return "Portuguese"
        case "ro": return "Romanian"
        case "ru": return "Russian"
        case "sr": return "Serbian"
        case "sk": return "Slovak"
        case "sl": return "Slovenian"
        case "es": return "Spanish"
        case "sv": return "Swedish"
        case "th": return "Thai"
        case "tr": return "Turkish"
        case "uk": return "Ukrainian"
        case "vi": return "Vietnamese"
        default: return code
        }
    }
}
#endif
