import SwiftUI

// SearchHistoryStore moved to SourcesShared/SearchHistoryStore.swift so the iOS/Mac search screen
// can reuse it (#90 ported to touch + Mac). Same per-profile, sync-backed store.

/// Search across every installed addon, on the engine (CatalogsWithExtra with a search extra).
struct SearchView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var profiles: ProfileStore
    @State private var showOpenLink = false
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncePending = false
    @State private var history: [String] = []
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    /// One complete result rail plus the following section heading. Only this bottom viewport scrolls;
    /// the system search field, keyboard, suggestions, and divider stay outside it and remain stationary.
    private var resultViewportHeight: CGFloat {
        let landscape = catalogPrefs.landscapeCards && apiKeys.hasTMDBArtwork
        let width = landscape ? kLandscapeCardWidth : catalogPrefs.posterWidth.tvWidth
        let artworkHeight = landscape ? width * 9 / 16 : width * 1.5
        let labelHeight: CGFloat = (catalogPrefs.hidePosterLabels || catalogPrefs.onCardMeta)
            ? 0 : Theme.Space.sm + 28
        let railHeight = artworkHeight + labelHeight + Theme.Space.lg * 2
        let currentHeading: CGFloat = 38
        let nextHeadingPeek: CGFloat = 52
        // Keep the viewport's clipping edge close to the fixed search divider, so the neighboring rail
        // remains visible instead of being covered by a deep black band. The active rail still owns the
        // complete focus window; larger portrait cards can expand this further.
        return max(620, railHeight + currentHeading + Theme.Space.sm + Theme.Space.xl + nextHeadingPeek)
    }

    var body: some View {
        Group {
            if account.isSignedIn { results } else { CoreEmptyState.signedOut }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var results: some View {
        ZStack(alignment: .bottomLeading) {
            // Keep `.searchable` on a separate, inert sibling. If it wraps the results viewport, tvOS
            // treats focused poster rows as part of the search presentation's own scroll region and
            // scrolls the navigation, field, keyboard, and suggestions offscreen with them.
            searchChromeHost
            if hasSearchQuery, !core.searchResults.isEmpty {
                resultRowsViewport
            } else {
                idleContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear {
            core.loadSearchSuggestions()
            history = SearchHistoryStore.load(profileID: profiles.activeID)
        }
        .onChange(of: query) { _, value in scheduleSearch(value) }
        .onChange(of: profiles.activeID) { _, id in
            history = SearchHistoryStore.load(profileID: id)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchChromeHost: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $query, prompt: "Movies or series")
        .searchSuggestions {
            ForEach(suggestionTitles, id: \.self) { title in
                Text(title).searchCompletion(title)
            }
        }
        .onSubmit(of: .search) {
            searchTask?.cancel()
            core.suggestSearch(query)
            searchNow(query)
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if !history.isEmpty && !isTyping {
                historySection
            }
            if !isTyping {
                Button { showOpenLink = true } label: {
                    Label(directLinksOnly ? "Play a direct link" : "Play a link or magnet", systemImage: "link")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .sheet(isPresented: $showOpenLink) { OpenLinkView() }
            }
            emptyState
        }
        .padding(.horizontal, Theme.Space.screenEdge)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xl)
        // The idle controls share the bottom anchor with result rails. Give them a taller viewport so
        // Recent Searches sits close to the fixed keyboard instead of floating in the lower half.
        .frame(height: 720, alignment: .topLeading)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Recent Searches").sectionTitleStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(history, id: \.self) { term in
                        Button {
                            query = term
                        } label: {
                            Label(term, systemImage: "clock")
                        }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    }
                    Button {
                        SearchHistoryStore.clear(profileID: profiles.activeID)
                        history = []
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.sm)
            }
            .padding(.horizontal, -Theme.Space.screenEdge)
        }
    }

    private var resultRowsViewport: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(resultSections, id: \.title) { section in
                    resultRow(title: section.title, items: section.items)
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xl)
        }
        .frame(height: resultViewportHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        HStack(spacing: Theme.Space.sm) {
            if isWaitingForCurrentQuery {
                ProgressView()
                    .tint(Theme.Palette.accent)
            }
            Text(emptyText)
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.Palette.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Space.xl)
    }

    private func resultRow(title: String, items: [CoreMeta]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).sectionTitleStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   menu: .catalog)
                            .simultaneousGesture(TapGesture().onEnded { _ in saveToHistory(query) })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)
            }
            // Cancel the parent VStack's screenEdge padding so the ScrollView reaches the screen
            // edge and its clip region starts there rather than at the first card's left edge.
            .padding(.horizontal, -Theme.Space.screenEdge)
        }
    }

    private var resultSections: [(title: String, items: [CoreMeta])] {
        let movies = core.searchResults.filter { $0.type == "movie" }
        let series = core.searchResults.filter { $0.type == "series" }
        let other = core.searchResults.filter { $0.type != "series" && $0.type != "movie" }
        return [
            ("Movies", movies),
            ("Series", series),
            ("Other", other),
        ].filter { !$0.items.isEmpty }
    }

    private var emptyText: String {
        if isWaitingForCurrentQuery { return "Searching..." }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Start typing to search across everything your add-ons cover."
            : "No matches for \"\(query)\"."
    }

    private var isTyping: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isWaitingForCurrentQuery: Bool {
        hasSearchQuery && (searchDebouncePending || core.searchIsLoading)
    }

    private var hasSearchQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private var suggestionTitles: [String] { core.searchSuggestionTitles(for: query) }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        searchDebouncePending = value.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            core.suggestSearch(value)
            searchNow(value)
            searchDebouncePending = false
        }
    }

    private func searchNow(_ value: String) {
        core.search(value)
    }

    private func saveToHistory(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        SearchHistoryStore.add(trimmed, profileID: profiles.activeID)
        history = SearchHistoryStore.load(profileID: profiles.activeID)
    }
}
