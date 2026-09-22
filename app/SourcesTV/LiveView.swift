import SwiftUI

private let kLiveGuideStripHeight: CGFloat = 510

/// Native tvOS Live TV, driven by the **stremio-core** engine (`CoreBridge.liveBoardRows`): the engine's
/// tv / channel / events catalogs rendered as focus-driven rows of square CHANNEL TILES, distinct from
/// the 2:3 poster rails the rest of the app uses. Channel art is a logo on a neutral surface card, not
/// box-art, so a dedicated `ChannelTile` (not a forked `PosterCard`) carries the right shape. Focusing a
/// tile feeds the same `BrowseHeroBackdrop` / `FocusedItemModel` that Home and Discover use; selecting one
/// pushes the standard `DetailView`, which has a Live branch (backdrop + name + LIVE badge + source list,
/// no VOD chrome) and plays through the player's live-tuned path. The screen reuses the engine + player
/// wholesale — no EPG, no M3U import.
///
/// Empty state: when no installed add-on exposes a live catalog there are no live rows, so the screen
/// nudges the user to the Add-ons tab rather than showing a blank surface.
struct LiveView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var presenter: PlayerPresenter
    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var hdHomeRun = HDHomeRunManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                // The living backdrop: whichever channel is focused fills the screen with its art and
                // details, exactly like Home/Discover. Pure presentation, never focusable.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: kLiveGuideStripHeight + 50)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if hdHomeRun.enabled, !hdHomeRun.channels.isEmpty {
                            HDHomeRunGuideView(channels: hdHomeRun.channels,
                                               programs: hdHomeRun.guidePrograms,
                                               currentPrograms: hdHomeRun.currentPrograms,
                                               deviceName: hdHomeRun.device?.friendlyName ?? "HDHomeRun",
                                               focusModel: focusModel) { channel in
                                play(channel)
                            }
                        } else if !core.liveBoardRows.isEmpty {
                            ForEach(core.liveBoardRows) { row in
                                CoreChannelRowView(row: row, focusModel: focusModel)
                            }
                        } else if !(hdHomeRun.enabled && !hdHomeRun.channels.isEmpty), account.isSignedIn {
                            emptyState
                        } else {
                            CoreEmptyState.signedOut
                        }
                    }
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xl)
                }
                .heroBottomStrip(height: kLiveGuideStripHeight)
                .ignoresSafeArea(.container, edges: [.trailing, .bottom])
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        // Widen the Home board so live catalogs (ordered after an add-on's movie/series catalogs, hence
        // outside the default window) hydrate here; re-run when add-ons finish loading async.
        .onAppear {
            core.ensureLiveCatalogsLoaded(); configureMetaSources(); seed()
            if hdHomeRun.enabled, hdHomeRun.channels.isEmpty {
                Task { await hdHomeRun.discover(); seed() }
            } else if hdHomeRun.enabled, hdHomeRun.guidePrograms.isEmpty {
                Task { await hdHomeRun.refreshGuide(); seed() }
            }
        }
        .onChange(of: core.liveBoardRows.first?.id) { seed() }
        .onChange(of: core.addons.count) { core.ensureLiveCatalogsLoaded(); configureMetaSources() }
    }

    /// The hero enrichment asks the user's own meta add-ons, so every channel id scheme resolves.
    private func configureMetaSources() {
        FocusedItemModel.configureMetaSources(
            transportUrls: core.addons.filter(\.providesMeta).map(\.transportUrl))
    }

    /// First render shows the first channel's art, so the hero is never an empty canvas.
    private func seed() {
        if hdHomeRun.enabled, let first = hdHomeRun.channels.first {
            focusModel.seedIfEmpty(first.focusedHero(program: hdHomeRun.currentPrograms[first.guideNumber],
                                                     deviceName: hdHomeRun.device?.friendlyName ?? "HDHomeRun"))
        } else {
            focusModel.seedIfEmpty(core.liveBoardRows.first?.items.first?.focusedHero)
        }
    }

    private func play(_ channel: HDHomeRunChannel) {
        guard let url = URL(string: channel.streamURL) else { return }
        let id = "hdhr:\(hdHomeRun.device?.deviceID ?? "tuner"):\(channel.guideNumber)"
        let meta = PlaybackMeta(libraryId: id, videoId: id, type: "tv", name: channel.guideName,
                                poster: nil, season: nil, episode: nil)
        presenter.request = PlaybackRequest(url: url, title: channel.guideName, meta: meta)
    }

    /// When no installed add-on exposes a live catalog, point the user at Add-ons rather than a blank page.
    private var emptyState: some View {
        CoreEmptyState(
            systemImage: "dot.radiowaves.left.and.right",
            title: "No Live TV add-ons installed",
            message: "Install an add-on that provides live TV, channels, or events in the Add-ons tab and its channels will show up here."
        )
        .frame(minHeight: 470)
    }
}

private extension HDHomeRunChannel {
    func focusedHero(program: HDHomeRunProgram?, deviceName: String) -> FocusedHero {
        let title = program?.title ?? guideName
        let time = program.map { "\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened))" }
        let detail = ["Channel \(guideNumber)", guideName, time, isHD ? "HD" : nil].compactMap { $0 }.joined(separator: " · ")
        return FocusedHero(id: "\(id)|\(program?.start.timeIntervalSince1970 ?? 0)", type: "tv", title: title,
                    backdrop: program?.imageURL ?? program?.channelImageURL,
                    metaLine: detail, overview: program?.summary ?? "Live television from \(deviceName).",
                    genreLine: program?.category, logo: nil)
    }
}

/// A compact electronic programme guide. Channel identity stays fixed at the left while every programme
/// shares one horizontally-scrolling time scale, so starts, endings and overlaps line up like a broadcast
/// grid. Moving through the grid still updates the fixed Home-style hero; selecting tunes the channel.
private struct HDHomeRunGuideView: View {
    let channels: [HDHomeRunChannel]
    let programs: [String: [HDHomeRunProgram]]
    let currentPrograms: [String: HDHomeRunProgram]
    let deviceName: String
    let focusModel: FocusedItemModel
    let onPlay: (HDHomeRunChannel) -> Void

    private let channelWidth: CGFloat = 230
    private let rowHeight: CGFloat = 100
    private let headerHeight: CGFloat = 48
    private let pointsPerMinute: CGFloat = 9

    private var guideStart: Date {
        let calendar = Calendar.current
        let now = Date()
        let minute = calendar.component(.minute, from: now)
        return calendar.date(byAdding: .minute, value: -(minute % 30), to: now) ?? now
    }

    private var guideEnd: Date { guideStart.addingTimeInterval(6 * 60 * 60) }
    private var timelineWidth: CGFloat { CGFloat(guideEnd.timeIntervalSince(guideStart) / 60) * pointsPerMinute }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            channelColumn
            Divider().overlay(Theme.Palette.hairline)
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    timelineRows
                    currentTimeLine
                }
                .frame(width: timelineWidth, alignment: .leading)
            }
        }
        .padding(.leading, Theme.Space.screenEdge)
        .padding(.trailing, -Theme.Space.screenEdge * 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var channelColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("LIVE GUIDE").font(Theme.Typography.eyebrow).tracking(2)
                Spacer(minLength: 4)
                Text(Date().formatted(.dateTime.weekday(.abbreviated)))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(width: channelWidth, height: headerHeight)
            .background(Theme.Palette.surface1.opacity(0.96))

            ForEach(channels) { channel in
                channelCell(channel)
            }
        }
    }

    private func channelCell(_ channel: HDHomeRunChannel) -> some View {
        let logo = currentPrograms[channel.guideNumber]?.channelImageURL
            ?? programs[channel.guideNumber]?.first?.channelImageURL
        return HStack(spacing: 12) {
            Text(channel.guideNumber)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 48, alignment: .leading)
            ZStack {
                if let logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else {
                            channelName(channel)
                        }
                    }
                } else {
                    channelName(channel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 56, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(width: channelWidth, height: rowHeight, alignment: .leading)
        .background(Theme.Palette.surface1.opacity(0.94))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.Palette.hairline) }
    }

    private func channelName(_ channel: HDHomeRunChannel) -> some View {
        Text(channel.guideName)
            .font(Theme.Typography.label)
            .lineLimit(2)
            .foregroundStyle(Theme.Palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineRows: some View {
        VStack(spacing: 0) {
            timelineHeader
            ForEach(channels) { channel in
                ZStack(alignment: .leading) {
                    Theme.Palette.surface1.opacity(0.78)
                    let listings = visiblePrograms(for: channel)
                    if listings.isEmpty {
                        HDHomeRunGuideCard(channel: channel,
                            program: currentPrograms[channel.guideNumber], deviceName: deviceName,
                            width: 300, height: rowHeight, onPlay: { onPlay(channel) }, focusModel: focusModel)
                    } else {
                        ForEach(listings, id: \.self) { program in
                            HDHomeRunGuideCard(channel: channel, program: program, deviceName: deviceName,
                                width: programWidth(program), height: rowHeight,
                                onPlay: { onPlay(channel) }, focusModel: focusModel)
                                .offset(x: programOffset(program))
                        }
                    }
                }
                .frame(width: timelineWidth, height: rowHeight, alignment: .leading)
                .clipped()
                .overlay(alignment: .bottom) { Divider().overlay(Theme.Palette.hairline) }
            }
        }
    }

    private var timelineHeader: some View {
        ZStack(alignment: .leading) {
            Theme.Palette.surface1.opacity(0.96)
            ForEach(0..<13, id: \.self) { index in
                let date = guideStart.addingTimeInterval(Double(index) * 30 * 60)
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(index == 0 ? Theme.Palette.accent : Theme.Palette.textPrimary)
                    .offset(x: CGFloat(index) * 30 * pointsPerMinute + 12)
            }
        }
        .frame(width: timelineWidth, height: headerHeight)
    }

    @ViewBuilder private var currentTimeLine: some View {
        let x = CGFloat(Date().timeIntervalSince(guideStart) / 60) * pointsPerMinute
        if x >= 0, x <= timelineWidth {
            Rectangle()
                .fill(Theme.Palette.accent)
                .frame(width: 3, height: headerHeight + CGFloat(channels.count) * rowHeight)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    private func visiblePrograms(for channel: HDHomeRunChannel) -> [HDHomeRunProgram] {
        (programs[channel.guideNumber] ?? []).filter { $0.end > guideStart && $0.start < guideEnd }
    }

    private func programOffset(_ program: HDHomeRunProgram) -> CGFloat {
        CGFloat(max(program.start.timeIntervalSince(guideStart), 0) / 60) * pointsPerMinute
    }

    private func programWidth(_ program: HDHomeRunProgram) -> CGFloat {
        let visibleStart = max(program.start, guideStart)
        let visibleEnd = min(program.end, guideEnd)
        return max(CGFloat(visibleEnd.timeIntervalSince(visibleStart) / 60) * pointsPerMinute, 44)
    }
}

private struct HDHomeRunGuideCard: View {
    let channel: HDHomeRunChannel
    let program: HDHomeRunProgram?
    let deviceName: String
    let width: CGFloat
    let height: CGFloat
    let onPlay: () -> Void
    let focusModel: FocusedItemModel

    var body: some View {
        Button(action: onPlay) {
            ZStack(alignment: .leading) {
                Theme.Palette.surface1
                VStack(alignment: .leading, spacing: 3) {
                    Text(program?.title ?? channel.guideName)
                        .font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    if let program {
                        Text("\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                        if program.start <= Date(), program.end > Date() {
                            GeometryReader { proxy in
                                Capsule().fill(Color.white.opacity(0.25))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Theme.Palette.accent)
                                            .frame(width: proxy.size.width * program.progress)
                                    }
                            }.frame(height: 3)
                        }
                    }
                    else { Text("Live now").font(.system(size: 14)).foregroundStyle(.secondary) }
                }
                .padding(12)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 1))
            .background { FocusReporter {
                focusModel.focus(channel.focusedHero(program: program, deviceName: deviceName))
            } }
        }
        .buttonStyle(CardFocusStyle())
    }
}

/// One Live row from the engine board: a titled, horizontally-scrolling band of square `ChannelTile`s.
/// The Live twin of `CoreCatalogRowView` — same header + spacing language, but square channel tiles
/// instead of 2:3 poster cards, and it feeds the focus model just like the poster rails do.
struct CoreChannelRowView: View {
    let row: CoreBoardRow
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(title: row.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(row.items) { item in
                        ChannelTile(meta: item,
                                    onFocus: focusModel.map { model in
                                        { model.focus(item.focusedHero) }
                                    })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A focusable square (1:1) channel tile: the channel's logo (preferred) or poster, fit on a neutral
/// surface card so logos with transparency / odd aspect ratios read cleanly — channels rarely have
/// box-art, so a `fit` on a surface beats a `fill` crop. Navigates to the standard `DetailView`, which
/// engages the Live branch via the channel's `type`; crafted focus (scale + ember glow + lift) comes from
/// `CardFocusStyle`, the same component the poster cards use, so the row matches the rest of the app.
struct ChannelTile: View {
    let meta: CoreMeta
    var onFocus: (() -> Void)? = nil

    private let side: CGFloat = kPosterWidth   // square, matching the poster column width

    /// Logo first (the channel mark), else poster — both are channel-identifying art.
    private var artURL: URL? { URL(string: meta.logo ?? meta.poster ?? "") }

    var body: some View {
        NavigationLink { DetailView(type: meta.type, id: meta.id) } label: { tileLabel }
            .buttonStyle(CardFocusStyle())
    }

    private var tileLabel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ZStack {
                Theme.Palette.surface1
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fit)
                            .padding(Theme.Space.md)
                    default:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            )
            Text(meta.name)
                .font(.system(size: 18, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: side, alignment: .leading)
        }
        .background { if let onFocus { FocusReporter(onFocus: onFocus) } }
    }
}
