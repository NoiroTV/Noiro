#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import os.log

/// Coordinates Gemini translation of a full subtitle track. Engine-agnostic: given the source bytes
/// + the parsed cues + the target language, it loads the disk cache, batch-translates the missing cues
/// (resume-aware — the current playback position translates first so a resumed movie isn't minutes
/// late), writes each chunk to cache, and calls back with the merged `{cueIndex → translatedText}` map
/// after every chunk so the caller can refresh the on-screen subtitle progressively.
///
/// The caller (each engine's external-subtitle path) keeps its own `SubtitleCueRenderer` and swaps the
/// active cue's text for the translated one as translations arrive; cues still pending show the original.
/// If translation is off / no key / Gemini fails, the original cues are unchanged — playback is never
/// left without subtitles.
@MainActor
final class SubtitleTranslator {
    static let shared = SubtitleTranslator()

    private static let logger = Logger(subsystem: "app.noiro", category: "SubtitleTranslator")
    // A normal movie/episode subtitle track fits in one Gemini Flash request. Keep a generous
    // character ceiling below the models' 65K output-token limit, and split only unusually large
    // tracks. The old 60-cue chunks turned one film into dozens of daily-quota requests.
    private static let maxBatchCueCount = 2_400
    private static let maxBatchCharacters = 120_000

    private var inFlightTask: Task<Void, Never>?

    private init() {}

    /// Whether translation should run for a track with the given source language, per the user's settings.
    /// `force` overrides "when needed" (the manual Translate action).
    func shouldTranslate(sourceLanguage: String?, force: Bool) -> Bool {
        guard PlaybackSettings.isSubtitleTranslationEnabled else { return false }
        if force { return true }
        switch PlaybackSettings.subtitleTranslationMode {
        case .always:
            return true
        case .whenNeeded:
            return SubtitleTranslationLanguagePolicy.shouldTranslateWhenNeeded(
                sourceLanguage: sourceLanguage,
                targetLanguage: PlaybackSettings.subtitleTranslationTargetLanguage,
                preferredSubtitleLanguages: TrackPreferences.current.subtitleLanguages
            )
        }
    }

    /// Translate a full cue track. Calls `onChunk` after every batch with the cumulative
    /// `{cueIndex → translatedText}` map (callers refresh their renderer from it). Cancels any prior
    /// pass (a new subtitle was loaded). `resumeSeconds` reorders so cues near the resume point land first.
    func translateTrack(
        sourceData: Data,
        sourceLanguage: String?,
        cues: [SubtitleCue],
        resumeSeconds: TimeInterval?,
        onChunk: @escaping ([Int: String]) -> Void
    ) {
        inFlightTask?.cancel()
        guard PlaybackSettings.isSubtitleTranslationEnabled else { return }
        guard let normalized = SubtitleTextTrackPolicy.normalizedWebVTT(from: sourceData) else { return }

        let sourceHash = SubtitleTranslationCache.sourceHash(for: normalized)
        let target = PlaybackSettings.subtitleTranslationTargetLanguage
        let provider = PlaybackSettings.subtitleTranslationProvider.rawValue
        let identity = SubtitleTranslationCache.identity(
            sourceHash: sourceHash, provider: provider,
            targetLanguage: target, sourceLanguage: sourceLanguage
        )

        inFlightTask = Task {
            var cached = await SubtitleTranslationCache.load(identity: identity) ?? [:]

            // Seed: publish whatever the cache already had so a repeat play is instant.
            if !cached.isEmpty { onChunk(cached) }

            // Build the per-cue translation inputs (id = cue index in the source track).
            let allCues = cues.enumerated().map { (idx, cue) in
                SubtitleTranslationCue(id: idx, text: cue.text)
            }
            let missing = allCues.filter { cached[$0.id] == nil }
            guard !missing.isEmpty else { return }

            // Normal tracks become one chronological request. If a rare oversized track must split,
            // translate the batch containing the resume point first while preserving dialogue order.
            let preferredCueID = Self.resumeCueID(
                resumeSeconds: resumeSeconds, total: allCues.count, cues: cues
            )
            for chunk in Self.translationBatches(missing, preferredCueID: preferredCueID) {
                var result: [Int: String] = [:]
                // A rate-limited chunk must remain at the head of the pass. Previously it was discarded
                // after one 429 and the loop advanced through the whole track, so a handful of early cues
                // translated and every later cue was permanently skipped. Wait for the service's adaptive
                // cooldown and retry this exact chunk until it succeeds or the track/player is replaced.
                while result.isEmpty {
                    guard !Task.isCancelled else { return }
                    result = await SubtitleTranslationService.shared.translateBatch(
                        cues: chunk, sourceLanguage: sourceLanguage, targetLanguage: target
                    )
                    guard !Task.isCancelled else { return }
                    if result.isEmpty {
                        let delay = await SubtitleTranslationService.shared.retryDelayAfterFailure()
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
                cached.merge(result) { _, new in new }
                await SubtitleTranslationCache.save(
                    translations: cached, identity: identity, sourceHash: sourceHash,
                    provider: provider, targetLanguage: target, sourceLanguage: sourceLanguage
                )
                onChunk(cached)
            }
        }
    }

    /// Translate a decoded embedded-subtitle timeline. KSPlayer exposes the current rolling window of
    /// embedded cues (up to its 255-frame subtitle queue), not the original subtitle file bytes. Stable
    /// millisecond cue ids plus `cacheSeed` let successive windows extend one persistent translation track:
    /// the first window is translated ahead of playback, then later windows fill the rest of the episode.
    func translateEmbeddedTimeline(
        cacheSeed: Data,
        sourceLanguage: String?,
        cues: [SubtitleTranslationCue],
        onChunk: @escaping ([Int: String]) -> Void,
        onComplete: @escaping () -> Void
    ) {
        inFlightTask?.cancel()
        guard PlaybackSettings.isSubtitleTranslationEnabled, !cues.isEmpty else {
            onComplete()
            return
        }

        let sourceHash = SubtitleTranslationCache.sourceHash(for: cacheSeed)
        let target = PlaybackSettings.subtitleTranslationTargetLanguage
        let provider = PlaybackSettings.subtitleTranslationProvider.rawValue
        let identity = SubtitleTranslationCache.identity(
            sourceHash: sourceHash, provider: provider,
            targetLanguage: target, sourceLanguage: sourceLanguage
        )

        inFlightTask = Task {
            defer { onComplete() }
            var cached = await SubtitleTranslationCache.load(identity: identity) ?? [:]
            if !cached.isEmpty { onChunk(cached) }

            let missing = cues.filter { cached[$0.id] == nil }
            guard !missing.isEmpty else { return }
            for chunk in Self.translationBatches(missing) {
                var result: [Int: String] = [:]
                while result.isEmpty {
                    guard !Task.isCancelled else { return }
                    result = await SubtitleTranslationService.shared.translateBatch(
                        cues: chunk, sourceLanguage: sourceLanguage, targetLanguage: target
                    )
                    guard !Task.isCancelled else { return }
                    if result.isEmpty {
                        let delay = await SubtitleTranslationService.shared.retryDelayAfterFailure()
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
                cached.merge(result) { _, new in new }
                await SubtitleTranslationCache.save(
                    translations: cached, identity: identity, sourceHash: sourceHash,
                    provider: provider, targetLanguage: target, sourceLanguage: sourceLanguage
                )
                onChunk(cached)
            }
        }
    }

    /// Cancel any in-flight track translation (player tearing down / new subtitle loaded).
    func cancel() {
        inFlightTask?.cancel()
        inFlightTask = nil
        embeddedTranslationCache.removeAll()
        embeddedTranslationTask?.cancel()
        embeddedTranslationTask = nil
        embeddedBatchTask?.cancel()
        embeddedBatchTask = nil
        embeddedPendingBatch.removeAll()
        embeddedInFlight.removeAll()
    }

    // MARK: - Embedded (live lookahead) translation

    /// In-memory cache for embedded cue text → translated text. Keyed by the original text so repeated
    /// cues (common in dialogue) don't re-call Gemini. Capped to avoid unbounded growth.
    private var embeddedTranslationCache: [String: String] = [:]
    private var embeddedTranslationTask: Task<Void, Never>?
    /// Texts currently being translated by Gemini (prevents re-requesting the same cue while in flight).
    private var embeddedInFlight = Set<String>()
    /// Throttle: the last time a NEW cue was sent to Gemini (embedded single-cue requests only).
    private var embeddedLastRequestAt: Date?
    private static let embeddedCacheCap = 300

    /// Translate a single embedded cue text (from mpv's `sub-text`). Returns the translated text from the
    /// cache if available; otherwise fires a background translation and calls `onResult` when it lands.
    /// While the translation is in flight, the caller shows the original text (never blanks).
    func translateEmbeddedCue(text: String, sourceLanguage: String?, onResult: @escaping (String) -> Void) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        // Cache hit → instant.
        if let cached = embeddedTranslationCache[cleaned] {
            onResult(cached); return
        }

        // Already translating → skip (the batch will cache it and onResult will fire).
        if embeddedInFlight.contains(cleaned) { return }

        // BATCHED approach (same as the external path): accumulate uncached cues into a pending list,
        // then flush them as a SINGLE translateBatch call every few seconds. This reduces the number of
        // Gemini API calls from 1-per-cue (which triggers 429 rate limits on the free tier) to
        // 1-per-batch (each translating up to 10 cues in one request). Mirrors how the external path
        // batches 60 cues per request.
        embeddedPendingBatch[cleaned] = onResult
        flushEmbeddedBatchIfNeeded(sourceLanguage: sourceLanguage, force: embeddedPendingBatch.count >= 10)
    }

    /// Flush the pending embedded cue batch: send all accumulated uncached cues as a single
    /// `translateBatch` call. Called on each new cue (debounced to max 1 batch per 5s) and when the
    /// batch reaches 10 cues.
    private var embeddedBatchTask: Task<Void, Never>?
    private var embeddedPendingBatch: [String: (String) -> Void] = [:]

    private func flushEmbeddedBatchIfNeeded(sourceLanguage: String?, force: Bool) {
        // Keep exactly one live batch in flight. New cues remain in `embeddedPendingBatch` and are flushed
        // when this batch completes. The previous implementation launched another task whenever ten more
        // cues accumulated, so a long scene could queue many requests behind the service gate and keep
        // consuming quota even after the on-screen cue had changed.
        guard embeddedBatchTask == nil else { return }

        // Debounce: don't flush more often than every 5s (prevents 429 on Gemini's free tier).
        let now = Date()
        if !force, let last = embeddedLastRequestAt, now.timeIntervalSince(last) < 5.0 {
            // A long cue may be the last event for several seconds. Schedule the flush instead of relying
            // on another sub-text event to arrive after the debounce window.
            if embeddedTranslationTask == nil {
                let remaining = 5.0 - now.timeIntervalSince(last)
                embeddedTranslationTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.embeddedTranslationTask = nil
                    self.flushEmbeddedBatchIfNeeded(sourceLanguage: sourceLanguage, force: true)
                }
            }
            return
        }

        guard !embeddedPendingBatch.isEmpty else { return }
        embeddedTranslationTask?.cancel()
        embeddedTranslationTask = nil

        // Cap at 10 cues per batch (keeps the request payload reasonable).
        let batch = Array(embeddedPendingBatch.prefix(10))
        let texts = batch.map { $0.key }
        let callbacks = Dictionary(uniqueKeysWithValues: batch.map { ($0.key, $0.value) })
        for t in texts {
            embeddedInFlight.insert(t)
            embeddedPendingBatch.removeValue(forKey: t)
        }
        embeddedLastRequestAt = now

        let target = PlaybackSettings.subtitleTranslationTargetLanguage
        let cues = texts.enumerated().map { SubtitleTranslationCue(id: $0.offset, text: $0.element) }

        // The guard above leaves this task as the only live batch until it finishes. Cancelling a batch
        // mid-request loses its result and makes a healthy request look like a translation failure, so let
        // this batch complete and then drain whatever new cues accumulated behind it.
        embeddedBatchTask = Task { [weak self] in
            guard let self else { return }
            let result = await SubtitleTranslationService.shared.translateBatch(
                cues: cues, sourceLanguage: sourceLanguage, targetLanguage: target
            )
            guard !Task.isCancelled else { return }
            let retryDelay: TimeInterval?
            if result.isEmpty {
                retryDelay = await SubtitleTranslationService.shared.retryDelayAfterFailure()
            } else {
                retryDelay = nil
            }
            await MainActor.run {
                self.embeddedBatchTask = nil
                self.trimEmbeddedCacheIfNeeded()
                for (i, text) in texts.enumerated() {
                    self.embeddedInFlight.remove(text)
                    if let translated = result[i], !translated.isEmpty {
                        self.embeddedTranslationCache[text] = translated
                        callbacks[text]?(translated)
                    } else if let callback = callbacks[text] {
                        // Keep failed/rate-limited cues pending. They used to be removed before the
                        // request and then lost forever when Gemini returned 429.
                        self.embeddedPendingBatch[text] = callback
                    }
                }
                if let retryDelay {
                    self.scheduleEmbeddedRetry(after: retryDelay, sourceLanguage: sourceLanguage)
                } else {
                    self.flushEmbeddedBatchIfNeeded(sourceLanguage: sourceLanguage, force: false)
                }
            }
        }
    }

    private func scheduleEmbeddedRetry(after delay: TimeInterval, sourceLanguage: String?) {
        embeddedTranslationTask?.cancel()
        embeddedTranslationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.embeddedTranslationTask = nil
            self.flushEmbeddedBatchIfNeeded(sourceLanguage: sourceLanguage, force: true)
        }
    }

    private func trimEmbeddedCacheIfNeeded() {
        guard embeddedTranslationCache.count >= Self.embeddedCacheCap else { return }
        // Simple eviction: drop the first 50 entries (not LRU, but cheap + bounded).
        let toRemove = Array(embeddedTranslationCache.keys.prefix(50))
        for key in toRemove { embeddedTranslationCache.removeValue(forKey: key) }
    }

    // MARK: - Helpers

    /// Finds the source cue containing the resume position. Used only to prioritize a batch when an
    /// exceptionally large track does not fit in one request.
    private static func resumeCueID(
        resumeSeconds: TimeInterval?,
        total: Int,
        cues: [SubtitleCue]
    ) -> Int? {
        guard let resumeSeconds, resumeSeconds > 0, total == cues.count, !cues.isEmpty else { return nil }
        return cues.firstIndex(where: { $0.end >= resumeSeconds }) ?? (cues.count - 1)
    }

    /// Packs as much of the subtitle track as safely fits into each Gemini request. Each batch remains
    /// chronological so the model retains dialogue context. Most films and episodes produce one batch.
    private static func translationBatches(
        _ cues: [SubtitleTranslationCue],
        preferredCueID: Int? = nil
    ) -> [[SubtitleTranslationCue]] {
        guard !cues.isEmpty else { return [] }

        var batches: [[SubtitleTranslationCue]] = []
        var current: [SubtitleTranslationCue] = []
        var currentCharacters = 0

        for cue in cues {
            // Include a small allowance for the JSON id/key syntax around every cue.
            let characters = cue.text.count + 32
            if !current.isEmpty,
               current.count >= maxBatchCueCount || currentCharacters + characters > maxBatchCharacters {
                batches.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(cue)
            currentCharacters += characters
        }
        if !current.isEmpty { batches.append(current) }

        guard let preferredCueID,
              let preferredIndex = batches.firstIndex(where: { batch in
                  batch.contains(where: { $0.id == preferredCueID })
              }),
              preferredIndex > 0 else { return batches }

        let forward = Array(batches[preferredIndex...])
        let earlier = Array(batches[..<preferredIndex].reversed())
        return forward + earlier
    }
}
#endif
