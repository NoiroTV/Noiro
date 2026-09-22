import SwiftUI

/// Discover, driven by the **stremio-core** engine (`CatalogWithFilters`): pick a type, catalog, and
/// genre from compact menus, then browse the selected catalog as one Home-style rail. Every menu
/// option carries the engine's own `request`, dispatched back on selection.
struct DiscoverView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @AppStorage("noiro.hideLiveTab") private var hideLiveTab = false   // also hide Live types from the Discover type filter
    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    /// Match Home's bottom viewport exactly so the Discover heading, selector bar, and single rail
    /// sit at the bottom of the screen instead of beginning in the middle of the hero.
    private let stripHeight = kHomeRailStripHeight

    /// A horizontal ScrollView expands vertically when it is no longer nested in the old vertical
    /// ScrollView. Pin it to the active card style's real height so the fixed stack stays bottom-aligned.
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
                // The living backdrop: art owns the screen, details pinned above the strip. The
                // title, compact menus, and one catalog rail live in the bottom strip.
                // Match Home's media-info baseline; the fixed controls/rail use Home's preview reserve below.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: stripHeight + 60)
                discoverContent
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        .onAppear { if core.discover == nil { core.loadDiscover() }; seed() }
        .onChange(of: core.discover?.items.first?.id) { seed() }
    }

    private func seed() {
        focusModel.seedIfEmpty(core.discover?.items.first?.focusedHero)
    }

    /// The normal single-catalog layout is deliberately NOT inside a vertical ScrollView. tvOS otherwise
    /// nudges the whole stack a few points whenever focus crosses between a menu and the poster rail. With
    /// no vertical scroll container, the title, menus, and rail remain pixel-fixed at the bottom while both
    /// nested horizontal scrollers keep their normal Siri Remote behavior. Home owns the optional
    /// Collections hub; Discover always keeps this fixed one-catalog composition.
    private var discoverContent: some View {
        discoverStack
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var discoverStack: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let discover = core.discover {
                filterMenus(discover.selectable)
                rail(discover.items, fixedHeight: true)
            } else if account.isSignedIn {
                BigSpinner()
                    .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
            } else {
                CoreEmptyState.signedOut
            }
        }
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm + kFixedHeroRowBottomReserve)
    }

    private func filterMenus(_ selectable: CoreDiscoverSelectable) -> some View {
        // With Live TV turned off, hide its content types (tv / channel / events / ...) from the Discover
        // type menu too, so a disabled Live surface leaves no orphan "Channel" option (owner report).
        let shownTypes = hideLiveTab
            ? selectable.types.filter { !LiveTypes.contains($0.type) }
            : selectable.types
        let genre = selectable.extra.first { $0.name.caseInsensitiveCompare("genre") == .orderedSame }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.md) {
                Menu {
                    ForEach(shownTypes) { type in
                        Button { core.selectDiscover(type.request) } label: {
                            menuOption(type.type.capitalized, selected: type.selected)
                        }
                    }
                } label: {
                    DiscoverDropdownLabel(
                        title: "Type",
                        selection: shownTypes.first(where: \.selected)?.type.capitalized ?? "Choose"
                    )
                }
                .buttonStyle(ChipButtonStyle())

                Menu {
                    ForEach(selectable.catalogs) { catalog in
                        Button { core.selectDiscover(catalog.request) } label: {
                            menuOption(catalog.catalog, selected: catalog.selected)
                        }
                    }
                } label: {
                    DiscoverDropdownLabel(
                        title: "Catalog",
                        selection: selectable.catalogs.first(where: \.selected)?.catalog ?? "Choose"
                    )
                }
                .buttonStyle(ChipButtonStyle())

                if let genre, !genre.options.isEmpty {
                    Menu {
                        ForEach(genre.options) { option in
                            Button { core.selectDiscover(option.request) } label: {
                                menuOption(AddonTerms.localize(option.label), selected: option.selected)
                            }
                        }
                    } label: {
                        DiscoverDropdownLabel(
                            title: "Genre",
                            selection: genre.options.first(where: \.selected)
                                .map { AddonTerms.localize($0.label) } ?? "All"
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

    @ViewBuilder private func rail(_ items: [CoreMeta], fixedHeight: Bool) -> some View {
        if items.isEmpty {
            BigSpinner()
                .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
        } else {
            PosterRailShell {
                EmptyView()
            } content: {
                LazyHStack(alignment: .top, spacing: Theme.Space.railItemGap) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   menu: .catalog,
                                   rating: item.imdbRating, year: item.releaseInfo, genres: item.genres,
                                   onFocus: { focusModel.focus(item.focusedHero) })
                            // Infinite scroll follows the same shared engine path as the old grid.
                            .onAppear { if item.id == items.last?.id { core.loadDiscoverNextPage() } }
                    }
                }
            }
            .frame(height: fixedHeight ? fixedRailHeight : nil, alignment: .top)
        }
    }
}

/// The compact, remote-friendly label used by each Discover menu. The field name stays visible so
/// the three selected values remain unambiguous even when an add-on uses an unusual catalog name.
struct DiscoverDropdownLabel: View {
    let title: String
    let selection: String

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(selection)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
