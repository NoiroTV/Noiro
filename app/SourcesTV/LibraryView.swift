import SwiftUI

/// Library, driven by the **stremio-core** engine (`LibraryWithFilters`): the user's saved titles with
/// type + sort filters. Auto-refreshes as the library changes (add/remove/mark watched), no reload.
struct LibraryView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var profiles: ProfileStore   // gate the Library on the active profile's own history
    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var downloads = DownloadStore.shared   // offline downloads section (#30)

    private let stripHeight = kHomeRailStripHeight

    /// Keep the fixed Library rail tied to the active Poster Style dimensions, exactly like Discover.
    private var fixedRailHeight: CGFloat {
        let landscape = catalogPrefs.landscapeCards && apiKeys.hasTMDBArtwork
        let width = landscape ? kLandscapeCardWidth : catalogPrefs.posterWidth.tvWidth
        let artworkHeight = landscape ? width * 9 / 16 : width * 1.5
        let titleHeight: CGFloat = (catalogPrefs.hidePosterLabels || catalogPrefs.onCardMeta)
            ? 0 : Theme.Space.sm + 28
        return artworkHeight + titleHeight + Theme.Space.lg * 2
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BrowseHeroBackdrop(model: focusModel, detailsBottom: stripHeight + 60)
                libraryContent
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        // Reload while empty: the library syncs from the API asynchronously after sign-in, so the
        // first load can land before ctx.library is populated. Revisiting the tab refills it.
        .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() }; seed() }
        .onChange(of: core.library?.catalog.first?.id) { seed() }
        .onChange(of: profiles.activeID) { seed() }
    }

    private func seed() {
        let first = profiles.activeUsesEngineHistory ? core.library?.catalog.first : profiles.libraryItems.first
        focusModel.seedIfEmpty(first?.focusedHero)
    }

    /// Library never has a vertical ScrollView around its controls and poster rail. tvOS otherwise
    /// recenters that entire stack whenever focus moves between cards. Downloads open in their own
    /// scrollable destination so their presence cannot change the Library rail's focus geometry.
    private var libraryContent: some View {
        libraryStack
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var libraryStack: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if profiles.activeUsesEngineHistory {
                if let library = core.library {
                    controls(library.selectable)
                    if library.catalog.isEmpty {
                        hint("Your library is empty. Add titles to your library in Stremio and they will show up here.")
                    } else {
                        rail(library.catalog, fixedHeight: true)
                    }
                } else if account.isSignedIn {
                    BigSpinner().padding(Theme.Space.xxl).frame(maxWidth: .infinity)
                } else {
                    CoreEmptyState.signedOut
                }
            } else {
                let items = profiles.libraryItems
                if !downloads.records.isEmpty { controls(nil) }
                if items.isEmpty {
                    hint("This profile's library is empty. Titles it watches show up here.")
                } else {
                    rail(items, fixedHeight: true)
                }
            }
        }
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm + kFixedHeroRowBottomReserve)
    }

    private func controls(_ selectable: CoreLibrarySelectable?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.md) {
                if !downloads.records.isEmpty {
                    NavigationLink {
                        ScrollView {
                            TVDownloadsView().padding(.vertical, Theme.Space.lg)
                        }
                        .background(Theme.Palette.canvas.ignoresSafeArea())
                    } label: {
                        Label("Downloads (\(downloads.records.count))", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(ChipButtonStyle())
                }

                if let selectable {
                    Menu {
                        ForEach(selectable.types) { type in
                            Button { core.selectLibrary(type.request) } label: {
                                menuOption(AddonTerms.localize(type.label), selected: type.selected)
                            }
                        }
                    } label: {
                        LibraryDropdownLabel(
                            title: "Type",
                            selection: AddonTerms.localize(selectable.types.first(where: \.selected)?.label ?? "All")
                        )
                    }
                    .buttonStyle(ChipButtonStyle())

                    Menu {
                        ForEach(selectable.sorts) { sort in
                            Button { core.selectLibrary(sort.request) } label: {
                                menuOption(AddonTerms.localize(sort.label), selected: sort.selected)
                            }
                        }
                    } label: {
                        LibraryDropdownLabel(
                            title: "Sort",
                            selection: AddonTerms.localize(selectable.sorts.first(where: \.selected)?.label ?? "Recent")
                        )
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
            .padding(.horizontal, Theme.Space.catalogChromeHorizontal)
            .padding(.vertical, Theme.Space.xs)
        }
    }

    private func menuOption(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).lineLimit(1)
            if selected { Image(systemName: "checkmark") }
        }
    }

    private func rail(_ items: [CoreCWItem], fixedHeight: Bool) -> some View {
        PosterRailShell {
            EmptyView()
        } content: {
            LazyHStack(alignment: .top, spacing: Theme.Space.railItemGap) {
                ForEach(items) { item in
                    PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                               progress: item.progress > 0 ? item.progress : nil,
                               isWatched: isWatched(item), menu: .library,
                               onFocus: { focusModel.focus(item.focusedHero) })
                }
            }
        }
        .frame(height: fixedHeight ? fixedRailHeight : nil, alignment: .top)
    }

    /// Watched badge for a Library tile, honoring the per-profile history invariant:
    /// the owner profile reads the engine's own watched bookkeeping (timesWatched);
    /// overlay profiles read only their private overlay (a whole-title mark records the
    /// metaId itself, episode finishes record episode ids), never the account's state.
    private func isWatched(_ item: CoreCWItem) -> Bool {
        profiles.activeUsesEngineHistory
            ? item.isWatched
            : !profiles.watchedVideoIds(forMeta: item.id).isEmpty
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, Theme.Space.catalogChromeHorizontal)
            .padding(.top, Theme.Space.lg)
    }
}

private struct LibraryDropdownLabel: View {
    let title: String
    let selection: String

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title).foregroundStyle(Theme.Palette.textTertiary)
            Text(selection).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
