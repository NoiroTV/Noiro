import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Native iPhone, iPad, and Mac person page. The card and spacing primitives are the same ones Home uses;
/// only the hero is person-first until a Mac focus/hover previews one of the already-loaded credits.
struct PersonDetailView: View {
    let route: PersonRoute
    @StateObject private var model: PersonProfileModel
    @State private var previewCredit: PersonMediaCredit?
    @State private var showingAbout = false
    @State private var gallery: PersonGalleryLaunch?

    init(route: PersonRoute) {
        self.route = route
        _model = StateObject(wrappedValue: PersonProfileModel(route: route))
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let profile = model.profile {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                            PersonHeroTouch(profile: profile, preview: previewCredit,
                                            height: heroHeight(geometry.size.height))
                            controls(profile)
                            ForEach(model.visibleSections) { section in
                                PersonMediaRailTouch(section: section, model: model,
                                                     previewCredit: $previewCredit)
                            }
                            if !profile.photos.isEmpty {
                                PersonPhotoRailTouch(photos: profile.photos, previewCredit: $previewCredit) { index in
                                    gallery = PersonGalleryLaunch(initialIndex: index)
                                }
                            }
                            Color.clear.frame(height: Theme.Space.xl)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if model.loadFailed {
                    failureState
                } else {
                    ProgressView().scaleEffect(1.35).tint(Theme.Palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task { model.load() }
        .platformFullScreenCover(isPresented: $showingAbout) {
            if let profile = model.profile { PersonAboutTouch(profile: profile) }
        }
        .platformFullScreenPlayerCover(item: $gallery) { launch in
            if let profile = model.profile {
                PersonGalleryTouch(photos: profile.photos, initialIndex: launch.initialIndex) { gallery = nil }
            }
        }
        .personNavigationChrome(title: route.name)
    }

    private func heroHeight(_ viewport: CGFloat) -> CGFloat {
        #if os(macOS)
        return min(700, max(560, viewport * 0.62))
        #else
        return max(430, viewport * 0.58)
        #endif
    }

    private func controls(_ profile: PersonProfile) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                previewCredit = nil
                showingAbout = true
            } label: {
                Label("About", systemImage: "person.text.rectangle")
                    .background { PersonFocusReporter { previewCredit = nil } }
            }
            .buttonStyle(PrimaryActionStyle())
            .onHover { if $0 { previewCredit = nil } }
            .accessibilityHint("Shows the full biography and facts")

            if !profile.photos.isEmpty {
                Button {
                    previewCredit = nil
                    gallery = PersonGalleryLaunch(initialIndex: 0)
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                        .background { PersonFocusReporter { previewCredit = nil } }
                }
                .buttonStyle(ChipButtonStyle())
                .onHover { if $0 { previewCredit = nil } }
                .accessibilityHint("Opens \(profile.photos.count) photos")
            }
        }
        .padding(.horizontal, Theme.Space.md)
    }

    private var failureState: some View {
        ContentUnavailableViewCompat(
            title: NSLocalizedString("Couldn’t Load Person", comment: "Person profile load failure title"),
            systemImage: "person.crop.circle.badge.exclamationmark",
            message: NSLocalizedString("Check your connection and try again.", comment: "Person profile load failure message"),
            cta: (title: NSLocalizedString("Retry", comment: "Retry an operation"), action: { model.retry() })
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PersonMediaRailTouch: View {
    let section: PersonMediaSection
    @ObservedObject var model: PersonProfileModel
    @Binding var previewCredit: PersonMediaCredit?
    @FocusState private var focusedID: String?

    var body: some View {
        let items = model.items(in: section)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(section.title)
                .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.sm) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        card(item)
                            .onAppear { model.requestResolution(section: section, through: index) }
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.xs)
            }
            .modifier(PersonRailClipModifier())
        }
        #if os(macOS)
        .onChange(of: focusedID) { _, id in
            guard let id else { return }
            if let item = items.first(where: { $0.id == id }) { previewCredit = item.credit }
        }
        #endif
    }

    private func card(_ item: PersonMediaItem) -> some View {
        let credit = item.credit
        let canonicalID: String
        let menu: iOSPosterMenu
        switch item.availability {
        case .available(let imdbID): canonicalID = imdbID; menu = .catalog
        case .pending, .unavailable: canonicalID = "tmdb:\(credit.tmdbID)"; menu = .none
        }
        let link = NavigationLink {
            iOSPersonMediaDestination(model: model, itemID: item.id, fallback: item)
        } label: {
            PosterCardiOS(id: canonicalID, type: credit.stremioType, name: credit.title,
                          poster: credit.posterURL, fallbackArt: credit.backdropURL,
                          imdbRating: credit.ratingText, year: credit.year, genres: nil,
                          progress: 0, menu: menu)
                .overlay(alignment: .topLeading) {
                    if item.availability == .unavailable {
                        Text("Not available in Noiro")
                            .font(Theme.Typography.eyebrow).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.black.opacity(0.72), in: Capsule()).padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(credit))
        .accessibilityHint(item.availability == .unavailable ? "Shows availability information" : "Opens details")

        #if os(macOS)
        return link
            .focusable()
            .focused($focusedID, equals: item.id)
            .macFocusRing(focusedID == item.id)
            .onHover { hovering in
                if hovering { previewCredit = credit }
            }
        #else
        return link
        #endif
    }

    private func accessibilityLabel(_ credit: PersonMediaCredit) -> String {
        guard let role = credit.role, !role.isEmpty else { return credit.title }
        return "\(credit.title), \(role)"
    }
}

private struct PersonPhotoRailTouch: View {
    let photos: [PersonPhoto]
    @Binding var previewCredit: PersonMediaCredit?
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Photos").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Space.sm) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        Button {
                            previewCredit = nil
                            open(index)
                        } label: {
                            PersonPlatformImage(url: photo.thumbnailURL, contentMode: .fill)
                                .frame(width: 150, height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                                .background { PersonFocusReporter { previewCredit = nil } }
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { previewCredit = nil } }
                        .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                        .accessibilityHint("Opens photo gallery")
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.xs)
            }
            .modifier(PersonRailClipModifier())
        }
    }
}

private struct PersonRailClipModifier: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) { content.scrollClipDisabled() } else { content }
    }
}

private struct PersonHeroTouch: View {
    let profile: PersonProfile
    let preview: PersonMediaCredit?
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PersonPlatformImage(url: preview?.backdropURL ?? preview?.posterURL
                                ?? profile.heroBackdropURL ?? profile.profileURL, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .blur(radius: preview == nil && profile.heroBackdropURL == nil && profile.profileURL != nil ? 18 : 0)
                .id(preview?.id ?? "person-\(profile.id)")
            LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.45), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, Theme.Palette.canvas.opacity(0.96)],
                           startPoint: .center, endPoint: .bottom)
            if preview == nil { portrait }
            details
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.lg)
        }
        .frame(height: height)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: preview?.id)
    }

    @ViewBuilder private var details: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 8) {
                Text(preview.title).font(Theme.Typography.hero).lineLimit(2).minimumScaleFactor(0.55)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(preview.metaLine).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                if let role = preview.role, !role.isEmpty {
                    Text(role).font(Theme.Typography.label).foregroundStyle(Theme.Palette.accent)
                }
                if let overview = preview.overview, !overview.isEmpty {
                    Text(overview).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(5).lineSpacing(5)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.name).font(Theme.Typography.hero).lineLimit(2).minimumScaleFactor(0.55)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let department = profile.knownForDepartment {
                    Text(department).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
                if let life = profile.lifeLine {
                    Text(life).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
                if let place = profile.placeOfBirth {
                    Text(place).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                if !profile.biography.isEmpty {
                    Text(profile.biography).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(5).lineSpacing(5)
                }
            }
        }
    }

    private var portrait: some View {
        Group {
            if profile.profileURL != nil {
                PersonPlatformImage(url: profile.profileURL, contentMode: .fit)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.Palette.accent.opacity(0.7), Theme.Palette.surface2],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(profile.initials).font(.system(size: 72, weight: .bold)).foregroundStyle(.white.opacity(0.82))
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        .frame(width: min(360, height * 0.52), height: height * 0.88, alignment: .bottom)
        .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.8),
                                    .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, Theme.Space.lg)
    }
}

private struct iOSPersonMediaDestination: View {
    @ObservedObject var model: PersonProfileModel
    let itemID: String
    let fallback: PersonMediaItem
    private var item: PersonMediaItem { model.item(withID: itemID) ?? fallback }

    @ViewBuilder var body: some View {
        switch item.availability {
        case .available(let imdbID):
            iOSDetailView(id: imdbID, type: item.credit.stremioType, title: item.credit.title,
                          seedBackdrop: item.credit.backdropURL, seedLogo: nil)
        case .pending:
            loading
                .task(id: itemID) { _ = await model.resolveNow(item) }
                .macBackAffordance()
        case .unavailable:
            unavailable.macBackAffordance()
        }
    }

    private var loading: some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView().scaleEffect(1.3).tint(Theme.Palette.accent)
            Text("Opening \(item.credit.title)…")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var unavailable: some View {
        ContentUnavailableViewCompat(
            title: item.credit.title,
            systemImage: "film.stack",
            message: NSLocalizedString(
                "Not available in Noiro. This TMDB credit does not have a playable Noiro title ID yet.",
                comment: "Unavailable person credit explanation"
            ),
            cta: (title: NSLocalizedString("Retry", comment: "Retry an operation"), action: {
                Task { _ = await model.resolveNow(item, retry: true) }
            })
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

private struct PersonAboutTouch: View {
    let profile: PersonProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let department = profile.knownForDepartment {
                        fact(NSLocalizedString("Known for", comment: "Person fact"), department)
                    }
                    if let life = profile.lifeLine {
                        fact(NSLocalizedString("Life", comment: "Person fact"), life)
                    }
                    if let place = profile.placeOfBirth {
                        fact(NSLocalizedString("Place of birth", comment: "Person fact"), place)
                    }
                    if !profile.biography.isEmpty {
                        Text("Biography").font(Theme.Typography.sectionTitle)
                        Text(profile.biography).font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary).lineSpacing(6)
                    }
                    if !profile.alsoKnownAs.isEmpty {
                        Text("Also known as").font(Theme.Typography.sectionTitle)
                        Text(profile.alsoKnownAs.joined(separator: "  ·  "))
                            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(Theme.Space.lg)
            }
            .navigationTitle(profile.name)
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.Typography.eyebrow).foregroundStyle(Theme.Palette.textTertiary)
            Text(value).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

private struct PersonGalleryLaunch: Identifiable {
    let id = UUID()
    let initialIndex: Int
}

private struct PersonGalleryTouch: View {
    let photos: [PersonPhoto]
    let initialIndex: Int
    let close: () -> Void
    @State private var index: Int

    init(photos: [PersonPhoto], initialIndex: Int, close: @escaping () -> Void) {
        self.photos = photos
        self.initialIndex = initialIndex
        self.close = close
        _index = State(initialValue: min(max(initialIndex, 0), max(photos.count - 1, 0)))
    }

    var body: some View {
        galleryBody
        #if os(macOS)
            .focusable()
            .onMoveCommand { direction in
                if direction == .left { index = max(0, index - 1) }
                if direction == .right { index = min(max(photos.count - 1, 0), index + 1) }
            }
            .onExitCommand(perform: close)
        #endif
    }

    private var galleryBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            galleryPages
            VStack {
                HStack {
                    Text("\(index + 1) of \(photos.count)")
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                        .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                    Spacer()
                    Button(action: close) { Label("Close", systemImage: "xmark") }
                        .buttonStyle(ChipButtonStyle())
                        .accessibilityHint("Dismisses the photo gallery")
                }
                Spacer()
            }
            .padding(Theme.Space.md)
        }
    }

    @ViewBuilder private var galleryPages: some View {
        #if os(macOS)
        if photos.indices.contains(index) {
            PersonPlatformImage(url: photos[index].url, contentMode: .fit, maxPixel: 2400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
            HStack {
                Button { index = max(0, index - 1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 28, weight: .bold))
                        .frame(width: 54, height: 80).background(.black.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain).disabled(index == 0).accessibilityLabel("Previous photo")
                Spacer()
                Button { index = min(photos.count - 1, index + 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 28, weight: .bold))
                        .frame(width: 54, height: 80).background(.black.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain).disabled(index >= photos.count - 1).accessibilityLabel("Next photo")
            }
            .foregroundStyle(.white).padding(.horizontal, Theme.Space.lg)
        }
        #else
        TabView(selection: $index) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { photoIndex, photo in
                PersonPlatformImage(url: photo.url, contentMode: .fit, maxPixel: 2400)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(photoIndex)
                    .accessibilityLabel("Photo \(photoIndex + 1) of \(photos.count)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
    }
}

private struct PersonPlatformImage: View {
    let url: String?
    let contentMode: ContentMode
    var maxPixel: CGFloat = 1600
    @State private var image: VXPosterImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                platformImage(image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Theme.Palette.surface2.overlay(
                    Image(systemName: "person.crop.rectangle").foregroundStyle(Theme.Palette.textTertiary)
                )
            } else {
                Theme.Palette.surface1.overlay(ProgressView().tint(Theme.Palette.textTertiary))
            }
        }
        .task(id: url) {
            image = nil; failed = false
            guard let url, !url.isEmpty else { failed = true; return }
            image = await PosterImageLoader.load(url, maxPixel: maxPixel)
            if image == nil, !Task.isCancelled { failed = true }
        }
    }

    private func platformImage(_ image: VXPosterImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}

private struct PersonFocusReporter: View {
    @Environment(\.isFocused) private var focused
    let onFocus: () -> Void
    var body: some View { Color.clear.onChange(of: focused) { value in if value { onFocus() } } }
}

private extension View {
    @ViewBuilder func personNavigationChrome(title: String) -> some View {
        #if os(iOS)
        self.navigationTitle(title).inlineNavigationTitle()
        #else
        self.macBackAffordance()
        #endif
    }
}
