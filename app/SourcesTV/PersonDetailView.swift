import SwiftUI
import UIKit

/// Home-style person page pushed from a real TMDB cast or crew card. The originating DetailView stays in
/// the same NavigationStack, so Back naturally restores person -> originating title in that order.
struct PersonDetailView: View {
    let route: PersonRoute
    @StateObject private var model: PersonProfileModel
    @State private var focusedCredit: PersonMediaCredit?
    @State private var focusedCatalogID: String?
    @State private var showingAbout = false
    @State private var showingGallery = false
    @State private var galleryIndex = 0
    @State private var heroRevision = 0
    @Namespace private var focusScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    init(route: PersonRoute) {
        self.route = route
        _model = StateObject(wrappedValue: PersonProfileModel(route: route))
    }

    private var railStripHeight: CGFloat {
        let landscape = catalogPrefs.landscapeCards && apiKeys.hasTMDBArtwork
        let width = landscape ? kLandscapeCardWidth : catalogPrefs.posterWidth.tvWidth
        let art = landscape ? width * 9 / 16 : width * 1.5
        let title: CGFloat = (catalogPrefs.hidePosterLabels || catalogPrefs.onCardMeta) ? 0 : Theme.Space.sm + 28
        return art + title + Theme.Space.lg * 2 + 76 + 120
    }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            if let profile = model.profile {
                hero(profile)
                actionRow(profile)
                filmography(profile)
            } else if model.loadFailed {
                failureState
            } else {
                BigSpinner().focusable()
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .trailing)
        .focusScope(focusScope)
        .task { model.load() }
        .fullScreenCover(isPresented: $showingAbout) {
            if let profile = model.profile { TVPersonAboutView(profile: profile) }
        }
        .fullScreenCover(isPresented: $showingGallery) {
            if let profile = model.profile { TVPersonGallery(photos: profile.photos, initialIndex: galleryIndex) }
        }
    }

    @ViewBuilder private func hero(_ profile: PersonProfile) -> some View {
        if let focusedCredit {
            TVPersonMediaHero(credit: focusedCredit,
                              catalogID: focusedCatalogID ?? "tmdb:\(focusedCredit.tmdbID)",
                              detailsBottom: railStripHeight + 80)
                .id("credit-\(focusedCredit.id)-\(heroRevision)")
                .transition(.opacity)
        } else {
            TVPersonHero(profile: profile, detailsBottom: railStripHeight + 80)
                .id("person-\(profile.id)-\(heroRevision)")
                .transition(.opacity)
        }
    }

    private func actionRow(_ profile: PersonProfile) -> some View {
        HStack(spacing: Theme.Space.md) {
            Button {
                focusedCredit = nil
                focusedCatalogID = nil
                showingAbout = true
            } label: {
                Label("About", systemImage: "person.text.rectangle")
                    .background { FocusReporter {
                        focusedCredit = nil
                        focusedCatalogID = nil
                    } }
            }
            .buttonStyle(PrimaryActionStyle())
            .prefersDefaultFocus(true, in: focusScope)
            .accessibilityHint("Shows the full biography and facts")

            if !profile.photos.isEmpty {
                Button {
                    focusedCredit = nil
                    focusedCatalogID = nil
                    galleryIndex = 0
                    showingGallery = true
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                        .background { FocusReporter {
                            focusedCredit = nil
                            focusedCatalogID = nil
                        } }
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .accessibilityHint("Opens \(profile.photos.count) photos")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, Theme.Space.catalogChromeHorizontal)
        .padding(.bottom, railStripHeight + 18)
    }

    private func filmography(_ profile: PersonProfile) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(model.visibleSections) { section in
                    PersonMediaRail(section: section, model: model, onDestinationReturn: {
                        focusedCredit = nil
                        focusedCatalogID = nil
                        heroRevision &+= 1
                    }) { item in
                        if reduceMotion {
                            focusedCredit = item.credit
                            focusedCatalogID = catalogID(for: item)
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) {
                                focusedCredit = item.credit
                                focusedCatalogID = catalogID(for: item)
                            }
                        }
                    }
                }
                if !profile.photos.isEmpty {
                    TVPersonPhotoRail(photos: profile.photos, onFocus: {
                        focusedCredit = nil
                        focusedCatalogID = nil
                    }) { index in
                        focusedCredit = nil
                        focusedCatalogID = nil
                        galleryIndex = index
                        showingGallery = true
                    }
                }
                Color.clear.frame(height: 120).accessibilityHidden(true)
            }
            .padding(.top, Theme.Space.sm)
        }
        .heroBottomStrip(height: railStripHeight)
        .scrollClipDisabled()
    }

    private func catalogID(for item: PersonMediaItem) -> String {
        if case .available(let id) = item.availability { return id }
        return "tmdb:\(item.credit.tmdbID)"
    }

    private var failureState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 62)).foregroundStyle(Theme.Palette.accent)
            Text("Couldn’t Load Person")
                .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text("Check your connection and try again.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Button("Retry") { model.retry() }
                .buttonStyle(PrimaryActionStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TVPersonPhotoRail: View {
    let photos: [PersonPhoto]
    let onFocus: () -> Void
    let open: (Int) -> Void

    var body: some View {
        PosterRailShell {
            RailHeader(title: NSLocalizedString("Photos", comment: "Person photo section"))
        } content: {
            LazyHStack(alignment: .top, spacing: Theme.Space.railItemGap) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button { open(index) } label: {
                        TVPersonPhotoCard(photo: photo)
                            .background { FocusReporter(onFocus: onFocus) }
                    }
                    .buttonStyle(CardFocusStyle(scale: 1))
                    .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                    .accessibilityHint("Opens photo gallery")
                }
            }
        }
    }
}

private struct TVPersonPhotoCard: View {
    let photo: PersonPhoto
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.Palette.surface2.overlay(BigSpinner())
            }
        }
        .frame(width: kPosterWidth, height: kPosterWidth * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .task(id: photo.id) { image = await PosterImageLoader.load(photo.thumbnailURL, maxPixel: 900) }
    }
}

private struct PersonMediaRail: View {
    let section: PersonMediaSection
    @ObservedObject var model: PersonProfileModel
    let onDestinationReturn: () -> Void
    let focused: (PersonMediaItem) -> Void

    var body: some View {
        let items = model.items(in: section)
        PosterRailShell {
            RailHeader(title: section.title)
        } content: {
            LazyHStack(alignment: .top, spacing: Theme.Space.railItemGap) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    mediaCard(item)
                        .onAppear { model.requestResolution(section: section, through: index) }
                }
            }
        }
    }

    private func mediaCard(_ item: PersonMediaItem) -> some View {
        let credit = item.credit
        let canonicalID: String
        let menu: PosterMenu
        switch item.availability {
        case .available(let id): canonicalID = id; menu = .catalog
        case .pending, .unavailable: canonicalID = "tmdb:\(credit.tmdbID)"; menu = .none
        }
        return PosterCard(
            title: credit.title,
            poster: credit.posterURL,
            type: credit.stremioType,
            id: canonicalID,
            menu: menu,
            rating: credit.ratingText,
            year: credit.year,
            focusScale: 1,
            onFocus: { focused(item) },
            destination: {
                AnyView(
                    TVPersonMediaDestination(model: model, itemID: item.id, fallback: item)
                        .onDisappear(perform: onDestinationReturn)
                )
            }
        )
        .overlay(alignment: .topLeading) {
            if item.availability == .unavailable {
                Text("Not available in Noiro")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(credit))
        .accessibilityHint(item.availability == .unavailable ? "Shows availability information" : "Opens details")
    }

    private func accessibilityLabel(_ credit: PersonMediaCredit) -> String {
        guard let role = credit.role, !role.isEmpty else { return credit.title }
        return "\(credit.title), \(role)"
    }
}

private struct TVPersonHero: View {
    let profile: PersonProfile
    let detailsBottom: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.Palette.canvas.ignoresSafeArea()
            HeroArtworkPanel(url: profile.heroBackdropURL ?? profile.profileURL) { EmptyView() }
                .blur(radius: profile.heroBackdropURL == nil ? 18 : 0)
            LinearGradient(colors: [.black.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea().allowsHitTesting(false)
            portrait
            details
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, Theme.Space.catalogChromeHorizontal)
                .padding(.bottom, detailsBottom)
        }
        .allowsHitTesting(false)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(profile.name)
                .font(Theme.Typography.hero).tracking(-1)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2).minimumScaleFactor(0.6)
            if let department = profile.knownForDepartment, !department.isEmpty {
                Text(department)
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.top, 12)
            }
            if let life = profile.lifeLine {
                Text(life).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.top, 6)
            }
            if let place = profile.placeOfBirth, !place.isEmpty {
                Text(place).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 6)
            }
            if !profile.biography.isEmpty {
                Text(profile.biography)
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(5).lineSpacing(6)
                    .padding(.top, 18)
            }
        }
    }

    private var portrait: some View {
        AsyncImage(url: URL(string: profile.profileURL ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fit)
            default:
                ZStack {
                    LinearGradient(colors: [Theme.Palette.accent.opacity(0.7), Theme.Palette.surface2],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(profile.initials)
                        .font(.system(size: 92, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                }
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            }
        }
        .frame(width: 420, height: 620, alignment: .bottom)
        .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.82),
                                    .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 54).padding(.trailing, 92)
    }
}

private struct TVPersonMediaHero: View {
    let credit: PersonMediaCredit
    let catalogID: String
    let detailsBottom: CGFloat
    @State private var logo: UIImage?

    var body: some View {
        let hero = focusedHero
        ZStack(alignment: .topLeading) {
            Theme.Palette.canvas.ignoresSafeArea()
            HeroArtworkPanel(url: hero.backdrop) { EmptyView() }
                .id(credit.id)
            // Reuse Home's exact fixed hero-info composition. Combined credits already contain every
            // preview field, so focus changes still perform no metadata or logo network work.
            HeroMediaInfoBlock(hero: hero, logo: logo)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, Theme.Space.catalogChromeHorizontal)
            .padding(.bottom, detailsBottom)
        }
        .allowsHitTesting(false)
        .task(id: "\(catalogID)|\(credit.id)") { await loadCachedLogo() }
    }

    private var focusedHero: FocusedHero {
        FocusedHero(
            id: "tmdb:\(credit.tmdbID)",
            type: credit.stremioType,
            title: credit.title,
            backdrop: credit.backdropURL ?? credit.posterURL,
            metaLine: credit.metaLine,
            overview: credit.overview,
            genreLine: credit.role,
            logo: nil
        )
    }

    /// The visible Home-style card has already asked the shared artwork cache for its logo. Poll that
    /// cache briefly and load only the resulting image URL; this never starts a title-metadata request as
    /// focus moves, but still gives the preview Home's clearlogo whenever the card resolved one.
    private func loadCachedLogo() async {
        logo = nil
        let tmdbID = "tmdb:\(credit.tmdbID)"
        let ids = catalogID == tmdbID ? [catalogID] : [catalogID, tmdbID]
        for attempt in 0..<10 {
            guard !Task.isCancelled else { return }
            for id in ids {
                if let raw = await LandscapeBackdropCache.cachedLogo(id: id),
                   let image = await PosterImageLoader.load(raw, maxPixel: 1280) {
                    guard !Task.isCancelled else { return }
                    logo = image
                    return
                }
            }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }
}

private struct TVPersonMediaDestination: View {
    @ObservedObject var model: PersonProfileModel
    let itemID: String
    let fallback: PersonMediaItem

    private var item: PersonMediaItem { model.item(withID: itemID) ?? fallback }

    var body: some View {
        Group {
            switch item.availability {
            case .available(let imdbID):
                DetailView(type: item.credit.stremioType, id: imdbID)
            case .pending:
                loading.task(id: itemID) { _ = await model.resolveNow(item) }
            case .unavailable:
                unavailable
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var loading: some View {
        VStack(spacing: Theme.Space.md) {
            BigSpinner()
            Text("Opening \(item.credit.title)…")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "film.stack")
                .font(.system(size: 60)).foregroundStyle(Theme.Palette.accent)
            Text(item.credit.title)
                .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text("Not available in Noiro")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Text("This credit is listed by TMDB, but it does not have a playable Noiro title ID yet.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 760)
            Button("Retry") {
                Task { _ = await model.resolveNow(item, retry: true) }
            }
            .buttonStyle(PrimaryActionStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TVPersonAboutView: View {
    let profile: PersonProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    HStack {
                        Text(profile.name).font(Theme.Typography.screenTitle)
                        Spacer()
                        Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                    if let department = profile.knownForDepartment { fact(NSLocalizedString("Known for", comment: "Person fact"), department) }
                    if let life = profile.lifeLine { fact(NSLocalizedString("Life", comment: "Person fact"), life) }
                    if let place = profile.placeOfBirth { fact(NSLocalizedString("Place of birth", comment: "Person fact"), place) }
                    if !profile.biography.isEmpty {
                        Text("Biography").font(Theme.Typography.sectionTitle)
                        Text(profile.biography)
                            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                            .lineSpacing(7)
                    }
                    if !profile.alsoKnownAs.isEmpty {
                        Text("Also known as").font(Theme.Typography.sectionTitle)
                        Text(profile.alsoKnownAs.joined(separator: "  ·  "))
                            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .padding(Theme.Space.screenEdge)
            }
        }
        .onExitCommand { dismiss() }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).eyebrowStyle()
            Text(value).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

private struct TVPersonGallery: View {
    let photos: [PersonPhoto]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(photos: [PersonPhoto], initialIndex: Int) {
        self.photos = photos
        self.initialIndex = initialIndex
        _index = State(initialValue: min(max(initialIndex, 0), max(photos.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { photoIndex, photo in
                    TVGalleryImage(url: photo.url)
                        .tag(photoIndex)
                        .accessibilityLabel("Photo \(photoIndex + 1) of \(photos.count)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            VStack {
                HStack {
                    Text("\(index + 1) of \(photos.count)")
                        .font(Theme.Typography.label).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                    Spacer()
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .accessibilityHint("Dismisses the photo gallery")
                }
                Spacer()
            }
            .padding(Theme.Space.screenEdge)
        }
        .onExitCommand { dismiss() }
    }
}

private struct TVGalleryImage: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                BigSpinner()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { image = await PosterImageLoader.load(url, maxPixel: 2160) }
    }
}
