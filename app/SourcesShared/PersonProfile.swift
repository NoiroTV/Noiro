import Foundation
import Combine

/// A stable navigation payload for a real TMDB person. Detail-page name-only fallbacks deliberately do
/// not create this route because a name cannot identify one person safely.
struct PersonRoute: Identifiable, Hashable {
    let id: Int
    let name: String
    let role: String?
    let profileURL: String?
}

enum PersonCreditKind: Hashable {
    case cast
    case crew
}

/// One raw movie or TV credit from TMDB's combined person credits. It already contains every field the
/// focus hero needs, so moving focus never starts a metadata or artwork request.
struct PersonMediaCredit: Identifiable, Hashable {
    let tmdbID: Int
    let mediaType: String                 // TMDB: movie or tv
    let title: String
    let posterURL: String?
    let backdropURL: String?
    let overview: String?
    let releaseDate: String?
    let voteAverage: Double?
    let popularity: Double
    let role: String?
    let department: String?
    let job: String?
    let kind: PersonCreditKind

    var id: String { "\(mediaType):\(tmdbID)" }
    var stremioType: String { mediaType == "tv" ? "series" : "movie" }
    var year: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }
    var ratingText: String? {
        guard let voteAverage, voteAverage > 0 else { return nil }
        return String(format: "%.1f", voteAverage)
    }
    var metaLine: String {
        var values: [String] = []
        if let year { values.append(year) }
        if let ratingText { values.append("★ \(ratingText)") }
        values.append(stremioType == "series" ? NSLocalizedString("Series", comment: "Media type")
                                                : NSLocalizedString("Movie", comment: "Media type"))
        return values.joined(separator: "  ·  ")
    }
}

enum PersonMediaAvailability: Hashable {
    case pending
    case available(String)                // canonical IMDb tt id
    case unavailable
}

struct PersonMediaItem: Identifiable, Hashable {
    let credit: PersonMediaCredit
    var availability: PersonMediaAvailability
    var id: String { credit.id }
}

struct PersonPhoto: Identifiable, Hashable {
    let path: String
    let url: String
    let thumbnailURL: String
    let width: Int?
    let height: Int?
    let aspectRatio: Double?
    var id: String { path }
}

enum PersonMediaSection: String, CaseIterable, Identifiable, Hashable {
    case knownFor
    case actingMovies
    case actingSeries
    case directing
    case writing
    case producing
    case otherCrew

    var id: String { rawValue }
    var title: String {
        switch self {
        case .knownFor: return NSLocalizedString("Known For", comment: "Person filmography section")
        case .actingMovies: return NSLocalizedString("Acting · Movies", comment: "Person filmography section")
        case .actingSeries: return NSLocalizedString("Acting · Series", comment: "Person filmography section")
        case .directing: return NSLocalizedString("Directing", comment: "Person filmography section")
        case .writing: return NSLocalizedString("Writing", comment: "Person filmography section")
        case .producing: return NSLocalizedString("Producing", comment: "Person filmography section")
        case .otherCrew: return NSLocalizedString("Other Crew", comment: "Person filmography section")
        }
    }
}

struct PersonProfile: Identifiable, Hashable {
    let id: Int
    let name: String
    let biography: String
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let knownForDepartment: String?
    let alsoKnownAs: [String]
    let profileURL: String?
    let credits: [PersonMediaCredit]
    let photos: [PersonPhoto]
    let heroBackdropURL: String?

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    var lifeLine: String? {
        let birth = Self.prettyDate(birthday)
        let death = Self.prettyDate(deathday)
        if let birthday, let deathday, let age = Self.age(from: birthday, to: deathday) {
            return [birth, death, String(format: NSLocalizedString("Died aged %d", comment: "Person age at death"), age)]
                .compactMap { $0 }.joined(separator: "  ·  ")
        }
        if let birthday, let age = Self.age(from: birthday, to: nil) {
            return [birth, String(format: NSLocalizedString("Age %d", comment: "Current person age"), age)]
                .compactMap { $0 }.joined(separator: "  ·  ")
        }
        return [birth, death].compactMap { $0 }.joined(separator: "  –  ").nilIfEmpty
    }

    private static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: iso)
    }

    private static func prettyDate(_ iso: String?) -> String? {
        guard let date = date(iso) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func age(from birthISO: String, to endISO: String?) -> Int? {
        guard let birth = date(birthISO) else { return nil }
        let end = date(endISO) ?? Date()
        guard end >= birth else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.year], from: birth, to: end).year
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Person responses are language scoped and near-immutable for the life of the app. The cache is session
/// only so changing app language cannot leak a biography from an earlier language into the new route.
actor PersonProfileSessionCache {
    static let shared = PersonProfileSessionCache()
    private var profiles: [String: PersonProfile] = [:]

    func profile(personID: Int, language: String) -> PersonProfile? {
        profiles["\(language.lowercased())|\(personID)"]
    }

    func store(_ profile: PersonProfile, language: String) {
        profiles["\(language.lowercased())|\(profile.id)"] = profile
    }
}

/// Session cache for title-id mapping. Nil results are cached too; the information-only destination can
/// explicitly invalidate one entry and retry when a temporary connectivity failure is suspected.
actor PersonExternalIDCache {
    static let shared = PersonExternalIDCache()
    private enum Value { case available(String), unavailable }
    private var values: [String: Value] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit = 6

    func resolve(_ credit: PersonMediaCredit) async -> String? {
        if let value = values[credit.id] {
            switch value { case .available(let id): return id; case .unavailable: return nil }
        }
        await acquire()
        if let value = values[credit.id] {
            release()
            switch value { case .available(let id): return id; case .unavailable: return nil }
        }
        guard !Task.isCancelled else { release(); return nil }
        let id = await TMDBClient.imdbID(forCatalogID: "tmdb:\(credit.tmdbID)", type: credit.stremioType)
        if !Task.isCancelled { values[credit.id] = id.map(Value.available) ?? .unavailable }
        release()
        guard !Task.isCancelled else { return nil }
        return id
    }

    func invalidate(_ credit: PersonMediaCredit) {
        values.removeValue(forKey: credit.id)
    }

    private func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()   // hand this permit directly to the oldest waiter
        } else {
            active = max(0, active - 1)
        }
    }
}

/// Page-scoped state: it publishes the raw combined credits immediately, then resolves their Noiro ids in
/// six-wide batches as rows appear. It never performs work during focus movement.
@MainActor
final class PersonProfileModel: ObservableObject {
    @Published private(set) var profile: PersonProfile?
    @Published private(set) var sections: [PersonMediaSection: [PersonMediaItem]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    let route: PersonRoute
    private var loadTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var queue: [PersonMediaCredit] = []
    private var queuedIDs = Set<String>()
    private var requestedDepth: [PersonMediaSection: Int] = [:]
    private var generation = 0
    private static let resolveChunk = 12
    private static let concurrentLimit = 6

    init(route: PersonRoute) {
        self.route = route
    }

    deinit {
        loadTask?.cancel()
        resolutionTask?.cancel()
    }

    var visibleSections: [PersonMediaSection] {
        PersonMediaSection.allCases.filter { !(sections[$0] ?? []).isEmpty }
    }

    func items(in section: PersonMediaSection) -> [PersonMediaItem] {
        sections[section] ?? []
    }

    func item(withID id: String) -> PersonMediaItem? {
        for section in PersonMediaSection.allCases {
            if let item = sections[section]?.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    func load(force: Bool = false) {
        if profile != nil, !force { return }
        generation += 1
        let token = generation
        loadTask?.cancel()
        resolutionTask?.cancel()
        queue.removeAll(); queuedIDs.removeAll(); requestedDepth.removeAll()
        if force { profile = nil; sections = [:] }
        isLoading = true; loadFailed = false
        let language = LocalizedMetadataLanguage.current
        loadTask = Task { [weak self] in
            let loaded = await TMDBClient.personProfile(personID: self?.route.id ?? 0, language: language)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.isLoading = false
            guard let loaded else { self.loadFailed = true; return }
            self.profile = loaded
            self.sections = Self.group(loaded.credits)
            // Prime only the first rail. Lower LazyVStack rows request their first chunk when they approach
            // the viewport, then each rail advances another chunk as its visible cards near that boundary.
            if let firstSection = self.visibleSections.first {
                self.requestResolution(section: firstSection, through: -1)
            }
        }
    }

    func retry() { load(force: true) }

    func cancelOutstandingWork() {
        generation += 1
        loadTask?.cancel(); loadTask = nil
        resolutionTask?.cancel(); resolutionTask = nil
        queue.removeAll(); queuedIDs.removeAll()
    }

    /// Called by media cells as they approach the end of a resolved chunk. All cards are already visible;
    /// this only advances Noiro-id resolution for that row.
    func requestResolution(section: PersonMediaSection, through index: Int) {
        let items = items(in: section)
        guard !items.isEmpty else { return }
        let current = requestedDepth[section] ?? 0
        var requested = max(current, min(items.count, Self.resolveChunk))
        if index >= max(0, requested - 4) { requested = min(items.count, requested + Self.resolveChunk) }
        guard requested > current else { return }
        requestedDepth[section] = requested
        for item in items.prefix(requested) where item.availability == .pending && queuedIDs.insert(item.id).inserted {
            queue.append(item.credit)
        }
        startResolutionIfNeeded()
    }

    func resolveNow(_ item: PersonMediaItem, retry: Bool = false) async -> String? {
        switch item.availability {
        case .available(let id) where !retry: return id
        case .unavailable where !retry: return nil
        default: break
        }
        if retry { await PersonExternalIDCache.shared.invalidate(item.credit) }
        let id = await PersonExternalIDCache.shared.resolve(item.credit)
        guard !Task.isCancelled else { return nil }
        applyResolution(creditID: item.id, imdbID: id)
        return id
    }

    private func startResolutionIfNeeded() {
        guard resolutionTask == nil, !queue.isEmpty else { return }
        let token = generation
        resolutionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, token == self.generation, !self.queue.isEmpty {
                let count = min(Self.concurrentLimit, self.queue.count)
                let batch = Array(self.queue.prefix(count))
                self.queue.removeFirst(count)
                let results = await withTaskGroup(of: (String, String?).self, returning: [(String, String?)].self) { group in
                    for credit in batch {
                        group.addTask {
                            let imdb = await PersonExternalIDCache.shared.resolve(credit)
                            return (credit.id, imdb)
                        }
                    }
                    var values: [(String, String?)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                guard !Task.isCancelled, token == self.generation else { return }
                for (creditID, imdbID) in results {
                    self.queuedIDs.remove(creditID)
                    self.applyResolution(creditID: creditID, imdbID: imdbID)
                }
            }
            if token == self.generation { self.resolutionTask = nil }
        }
    }

    private func applyResolution(creditID: String, imdbID: String?) {
        for section in PersonMediaSection.allCases {
            guard var values = sections[section], let index = values.firstIndex(where: { $0.id == creditID }) else { continue }
            values[index].availability = imdbID.map(PersonMediaAvailability.available) ?? .unavailable
            sections[section] = values
        }
    }

    private static func group(_ credits: [PersonMediaCredit]) -> [PersonMediaSection: [PersonMediaItem]] {
        let cast = deduplicate(credits.filter { $0.kind == .cast })
        let crew = deduplicate(credits.filter { $0.kind == .crew }, joiningRoles: true)
        let known = deduplicate(cast + crew)
            .sorted { lhs, rhs in
                if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
                return newest(lhs, rhs)
            }
            .prefix(20)

        var result: [PersonMediaSection: [PersonMediaItem]] = [:]
        result[.knownFor] = known.map { PersonMediaItem(credit: $0, availability: .pending) }
        result[.actingMovies] = newestFirst(cast.filter { $0.mediaType == "movie" }).map(pending)
        result[.actingSeries] = newestFirst(cast.filter { $0.mediaType == "tv" }).map(pending)
        result[.directing] = newestFirst(crew.filter { category($0) == .directing }).map(pending)
        result[.writing] = newestFirst(crew.filter { category($0) == .writing }).map(pending)
        result[.producing] = newestFirst(crew.filter { category($0) == .producing }).map(pending)
        result[.otherCrew] = newestFirst(crew.filter { category($0) == .otherCrew }).map(pending)
        return result
    }

    private static func pending(_ credit: PersonMediaCredit) -> PersonMediaItem {
        PersonMediaItem(credit: credit, availability: .pending)
    }

    private static func newestFirst(_ values: [PersonMediaCredit]) -> [PersonMediaCredit] {
        values.sorted(by: newest)
    }

    private static func newest(_ lhs: PersonMediaCredit, _ rhs: PersonMediaCredit) -> Bool {
        let ld = lhs.releaseDate ?? ""
        let rd = rhs.releaseDate ?? ""
        if ld != rd { return ld > rd }
        if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func deduplicate(_ values: [PersonMediaCredit], joiningRoles: Bool = false) -> [PersonMediaCredit] {
        var order: [String] = []
        var byID: [String: PersonMediaCredit] = [:]
        for credit in values {
            guard var existing = byID[credit.id] else {
                byID[credit.id] = credit; order.append(credit.id); continue
            }
            let roles = [existing.role, credit.role]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let combinedRole = joiningRoles ? Array(NSOrderedSet(array: roles)).compactMap { $0 as? String }.joined(separator: " · ")
                                            : (existing.role ?? credit.role)
            if credit.popularity > existing.popularity {
                existing = credit
            }
            existing = PersonMediaCredit(tmdbID: existing.tmdbID, mediaType: existing.mediaType,
                                         title: existing.title, posterURL: existing.posterURL,
                                         backdropURL: existing.backdropURL, overview: existing.overview,
                                         releaseDate: existing.releaseDate, voteAverage: existing.voteAverage,
                                         popularity: max(existing.popularity, credit.popularity),
                                         role: combinedRole?.nilIfEmpty ?? existing.role,
                                         department: existing.department ?? credit.department,
                                         job: existing.job ?? credit.job, kind: existing.kind)
            byID[credit.id] = existing
        }
        return order.compactMap { byID[$0] }
    }

    private static func category(_ credit: PersonMediaCredit) -> PersonMediaSection {
        let department = (credit.department ?? "").lowercased()
        let job = (credit.job ?? credit.role ?? "").lowercased()
        if department == "directing" || job.contains("director") { return .directing }
        if department == "writing" || job.contains("writer") || job.contains("screenplay") || job.contains("story") { return .writing }
        if department == "production" || job.contains("producer") { return .producing }
        return .otherCrew
    }
}
