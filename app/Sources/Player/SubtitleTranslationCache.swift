#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import CryptoKit

/// Caching + format normalization + language gating for Gemini subtitle translation. Ports Vortexo's
/// `SubtitleTranslationPersistentCachePolicy`, `SubtitleTextTrackPolicy`, and the disk cache shape.
///
/// - Disk cache: full-track translations persist at `<AppSupport>/SubtitleTranslations/<sha>.json`,
///   keyed by `SHA256("<sourceHash>|<provider>|<targetLanguage>|<sourceLanguage>")`, so a repeat play of
///   the same file+language is free. Entries follow the user-selected retention period and are excluded from
///   backup.
/// - WebVTT normalizer: canonicalizes SRT/ASS/VTT into a stable text form for hashing + chunking, since
///   Noiro's `SubtitleCueRenderer.parse` handles display parsing separately.
/// - Language policy: the "when needed" gate decides whether a source track needs translation at all.

// MARK: - WebVTT normalization

enum SubtitleTextTrackPolicy {
    private nonisolated static let extractableCodecs: Set<String> = [
        "ass", "ssa", "srt", "subrip", "text", "tx3g", "mov_text", "vtt", "webvtt"
    ]

    nonisolated static func isExtractable(codec: String?) -> Bool {
        guard let codec else { return false }
        return extractableCodecs.contains(codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Normalize SRT/ASS/VTT bytes into canonical WebVTT text. Used to hash a file for cache identity
    /// and to produce a stable chunked form for translation. Returns nil for non-text / unparseable input.
    nonisolated static func normalizedWebVTT(from data: Data) -> Data? {
        guard let decoded = decodedText(from: data) else { return nil }
        let content = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        if content.hasPrefix("WEBVTT") {
            guard containsTimedCue(content) else { return nil }
            return (content + "\n").data(using: .utf8)
        }
        if looksLikeASS(content) { return normalizedASSWebVTT(from: content) }
        return normalizedSRTWebVTT(from: content)
    }

    private nonisolated static func decodedText(from data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .isoLatin1] {
            if let value = String(data: data, encoding: encoding), !value.isEmpty {
                return value.replacingOccurrences(of: "\u{feff}", with: "")
            }
        }
        return nil
    }

    private nonisolated static func containsTimedCue(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains { $0.contains("-->") }
    }

    private nonisolated static func looksLikeASS(_ content: String) -> Bool {
        content.localizedCaseInsensitiveContains("[Events]")
            && content.components(separatedBy: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("dialogue:")
            }
    }

    private nonisolated static func normalizedSRTWebVTT(from content: String) -> Data? {
        var output = "WEBVTT\n\n"
        var cueCount = 0
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                cueCount += 1
                output += line.replacingOccurrences(of: ",", with: ".") + "\n"
            } else if trimmed.isEmpty {
                output += "\n"
            } else if Int(trimmed) == nil {
                output += line + "\n"
            }
        }
        guard cueCount > 0 else { return nil }
        return output.data(using: .utf8)
    }

    private nonisolated static func normalizedASSWebVTT(from content: String) -> Data? {
        let lines = content.components(separatedBy: "\n")
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var isInEvents = false
        var output = "WEBVTT\n\n"
        var cueCount = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                isInEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard isInEvents else { continue }

            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst("format:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = fields.firstIndex(of: "start"),
                  let endIndex = fields.firstIndex(of: "end"),
                  let textIndex = fields.firstIndex(of: "text") else { continue }

            let payload = String(line.dropFirst("dialogue:".count)).trimmingCharacters(in: .whitespaces)
            let values = payload.split(separator: ",", maxSplits: max(0, fields.count - 1), omittingEmptySubsequences: false).map(String.init)
            guard values.indices.contains(startIndex),
                  values.indices.contains(endIndex),
                  values.indices.contains(textIndex),
                  let start = normalizedASSTimestamp(values[startIndex]),
                  let end = normalizedASSTimestamp(values[endIndex]) else { continue }

            let text = values[textIndex]
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            cueCount += 1
            output += "\(start) --> \(end)\n\(text)\n\n"
        }
        guard cueCount > 0 else { return nil }
        return output.data(using: .utf8)
    }

    private nonisolated static func normalizedASSTimestamp(_ value: String) -> String? {
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard components.count == 3,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Double(components[2]),
              hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        let wholeSeconds = Int(seconds)
        let milliseconds = Int(((seconds - Double(wholeSeconds)) * 1_000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, wholeSeconds, milliseconds)
    }
}

// MARK: - Language policy (the "when needed" gate)

/// Decides whether a source subtitle track needs translation given the user's preferred subtitle
/// languages + the translation target. In "when needed" mode, tracks already in an accepted language
/// (the user's earlier preferences or the target) show as-is; everything else gets translated.
enum SubtitleTranslationLanguagePolicy {
    nonisolated static func shouldTranslateWhenNeeded(
        sourceLanguage: String?,
        targetLanguage: String,
        preferredSubtitleLanguages: [String]
    ) -> Bool {
        guard let sourceLanguage else { return true }
        let sourceTokens = languageTokens(for: sourceLanguage)
        guard !sourceTokens.isEmpty, !sourceTokens.contains("und") else { return true }

        return languagesAcceptedWithoutTranslation(
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            targetLanguage: targetLanguage
        )
        .allSatisfy { acceptedLanguage in
            sourceTokens.isDisjoint(with: languageTokens(for: acceptedLanguage))
        }
    }

    /// The languages that do NOT need translation: earlier preferences (kept as-is) + the target itself
    /// (if it isn't already among them). The LAST preference is treated as translate-eligible.
    nonisolated static func languagesAcceptedWithoutTranslation(
        preferredSubtitleLanguages: [String],
        targetLanguage: String
    ) -> [String] {
        let orderedPreferences = preferredSubtitleLanguages.filter { language in
            let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && normalized != "none"
        }
        var acceptedLanguages = Array(orderedPreferences.dropLast())
        let targetTokens = languageTokens(for: targetLanguage)
        if !targetTokens.isEmpty,
           acceptedLanguages.allSatisfy({ languageTokens(for: $0).isDisjoint(with: targetTokens) }) {
            acceptedLanguages.append(targetLanguage)
        }
        return acceptedLanguages
    }

    /// Alias-set token matching so "eng"/"en"/"English" all match (and hr/sr/bs, relevant to this app).
    nonisolated static func languageTokens(for rawValue: String) -> Set<String> {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "none" else { return [] }

        let aliasGroups: [[String]] = [
            ["en", "eng", "english", "en-us", "en-gb"],
            ["es", "spa", "spanish", "es-es", "es-419"],
            ["fr", "fra", "fre", "french"],
            ["de", "deu", "ger", "german"],
            ["it", "ita", "italian"],
            ["pt", "por", "portuguese", "pt-br", "pt-pt"],
            ["ru", "rus", "russian"],
            ["ja", "jpn", "japanese"],
            ["ko", "kor", "korean"],
            ["zh", "zho", "chi", "chinese", "cmn"],
            ["ar", "ara", "arabic"],
            ["hi", "hin", "hindi"],
            ["hr", "hrv", "scr", "cro", "croatian", "hrvatski"],
            ["sr", "srp", "scc", "serbian", "srpski"],
            ["bs", "bos", "bosnian", "bosanski"],
            ["und", "unknown"]
        ]

        var tokens = Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty })
        tokens.insert(normalized)
        for group in aliasGroups where group.contains(normalized) || !tokens.isDisjoint(with: Set(group)) {
            tokens.formUnion(group)
        }
        return tokens
    }
}

// MARK: - Persistent cache

/// On-disk cached translation for one subtitle file + language + provider. Versioned so the shape can
/// evolve; the loader validates version + identity before trusting it.
struct CachedSubtitleTranslations: Codable {
    let version: Int
    let sourceHash: String
    let provider: String
    let targetLanguage: String
    let sourceLanguage: String?
    let translations: [Int: String]
}

enum SubtitleTranslationCache {
    nonisolated private static let directoryName = "SubtitleTranslations"
    nonisolated private static let cacheVersion = 2
    /// A repeat playback refreshes the file's modification date, so frequently watched titles remain cached
    /// while abandoned translations are removed automatically. nil means the user selected Unlimited.
    nonisolated static var retentionInterval: TimeInterval? {
        PlaybackSettings.subtitleTranslationCachePeriod.retentionInterval
    }

    /// SHA-256 hex of the source subtitle bytes — the file identity (stable across the file's lifetime,
    /// independent of where it was downloaded from).
    nonisolated static func sourceHash(for data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// The cache identity for a given source + translation config. Two identical files translated to the
    /// same language by the same provider share a cache entry.
    nonisolated static func identity(
        sourceHash: String,
        provider: String,
        targetLanguage: String,
        sourceLanguage: String?
    ) -> String {
        let raw = "\(sourceHash)|\(provider)|\(targetLanguage)|\(sourceLanguage ?? "auto")"
        return SHA256.hash(data: Data(raw.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func rootURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Load a cached translation if present + valid (version + identity match). nil otherwise.
    nonisolated static func load(identity: String) async -> [Int: String]? {
        guard let fileURL = cacheFileURL(for: identity) else { return nil }
        if isExpired(fileURL) {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard
              let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedSubtitleTranslations.self, from: data) else { return nil }
        guard cached.version == cacheVersion else { return nil }
        // Sliding retention: successfully reusing a translation restarts the selected retention period.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return cached.translations.isEmpty ? nil : cached.translations
    }

    /// Persist a (possibly partial) translation set. Safe to call after each batch so progress survives
    /// an interrupted pass. Creates the cache directory + excludes it from backup.
    nonisolated static func save(
        translations: [Int: String],
        identity: String,
        sourceHash: String,
        provider: String,
        targetLanguage: String,
        sourceLanguage: String?
    ) async {
        guard let dir = rootURL() else { return }
        let fileURL = dir.appendingPathComponent("\(identity).json")
        let entry = CachedSubtitleTranslations(
            version: cacheVersion,
            sourceHash: sourceHash,
            provider: provider,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage,
            translations: translations
        )
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            pruneExpiredEntries(in: dir)
            var mutableDir = dir
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableDir.setResourceValues(resourceValues)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort cache; a write failure just means the next pass retranslates.
        }
    }

    nonisolated private static func cacheFileURL(for identity: String) -> URL? {
        rootURL()?.appendingPathComponent("\(identity).json")
    }

    nonisolated private static func isExpired(
        _ fileURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard let retentionInterval,
              let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) > retentionInterval
    }

    /// Saving any translation opportunistically clears every stale cache entry. This keeps disk usage bounded
    /// even when an expired title is never opened again.
    nonisolated private static func pruneExpiredEntries(
        in directory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for fileURL in files where fileURL.pathExtension == "json" && isExpired(fileURL, now: now, fileManager: fileManager) {
            try? fileManager.removeItem(at: fileURL)
        }
    }
}
#endif
