#if os(tvOS) && canImport(KSPlayer)
import AVFoundation
import KSPlayer
import SwiftUI
import UIKit

/// The direct-play engine used on Apple TV hardware. It deliberately mounts KSPlayer's low-level
/// `KSPlayerLayer` instead of KSPlayer's own controls: Noiro keeps its existing chrome, resume logic,
/// source recovery and AI subtitle overlay while KSPlayer owns FFmpeg demux, VideoToolbox decode and
/// direct Metal presentation.
private final class NoiroKSOptions: KSOptions {
    override func videoFrameMaxCount(fps: Float, naturalSize: CGSize, isLive: Bool) -> UInt8 {
        if isLive { return 8 }
        let pixels = naturalSize.width * naturalSize.height
        let target = Int(max(24, ceil(Double(max(fps, 24)) * 1.25)))
        return UInt8(min(pixels >= 3_800_000 ? 32 : 64, target))
    }
}

struct KSPlayerEngineView: UIViewRepresentable {
    @ObservedObject var coordinator: MPVMetalPlayerView.Coordinator

    func play(_ url: URL, headers: [String: String]? = nil, isDolbyVision: Bool = false) -> Self {
        coordinator.playUrl = url
        coordinator.playHeaders = headers
        coordinator.contentIsDolbyVision = isDolbyVision
        return self
    }

    func live(_ live: Bool) -> Self {
        coordinator.playLive = live
        return self
    }

    func onPropertyChange(_ handler: @escaping (any PlayerEngine, String, Any?) -> Void) -> Self {
        coordinator.onPropertyChange = handler
        return self
    }

    func makeCoordinator() -> MPVMetalPlayerView.Coordinator { coordinator }

    func makeUIView(context: Context) -> KSPlayerHostView {
        let host = KSPlayerHostView()
        let engine = KSPlayerEngineController(host: host)
        engine.playDelegate = coordinator
        engine.contentIsDolbyVision = coordinator.contentIsDolbyVision
        coordinator.player = engine
        host.engine = engine
        if let url = coordinator.playUrl {
            engine.loadFile(url, headers: coordinator.playHeaders, live: coordinator.playLive)
        }
        return host
    }

    func updateUIView(_ uiView: KSPlayerHostView, context: Context) {}

    static func dismantleUIView(_ uiView: KSPlayerHostView,
                                coordinator: MPVMetalPlayerView.Coordinator) {
        uiView.engine?.stop()
        uiView.engine = nil
    }
}

final class KSPlayerHostView: UIView {
    let videoContainer = UIView()
    let subtitleOverlay = SubtitleOverlayView()
    var engine: KSPlayerEngineController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoContainer.backgroundColor = .black
        videoContainer.frame = bounds
        videoContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(videoContainer)
        subtitleOverlay.frame = bounds
        subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(subtitleOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

@MainActor
final class KSPlayerEngineController: NSObject, PlayerEngine, KSPlayerLayerDelegate {
    weak var playDelegate: MPVPlayerDelegate?
    weak var host: KSPlayerHostView?
    private var layer: KSPlayerLayer?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var currentLive = false
    private var requestedRate: Float = 1
    private var subDelay: TimeInterval = 0
    private var lastSubtitleText: String?
    private var lastPresentedSubtitleText: String?
    private var activeSubtitleParts: [SubtitlePart] = []
    private var selectedAudioIndex: Int?
    private var selectedSubtitleIndex: Int?
    /// Whole-track AI translation state for KSPlayer's embedded subtitle queue. The decoder exposes up to
    /// 255 upcoming cues; each completed window is cached and the next window extends it as playback moves.
    private var embeddedTimelineTranslationRunning = false
    private var embeddedTimelinePlannedThrough: TimeInterval = 0
    private var embeddedTranslatedByCueID: [Int: String] = [:]
    private var selectedEmbeddedSubtitleInfo: (any SubtitleInfo)?
    private var selectedEmbeddedSubtitleLanguage: String?
    private var lastEmittedDuration: TimeInterval?
    private var lastEmittedBufferedEdge: TimeInterval?
    /// KSPlayer's layer clock fires every 100 ms. Vortexo deliberately keeps that delegate empty and
    /// publishes its UI clock from a 500 ms timer; matching that cadence here prevents Noiro's much heavier
    /// progress/resume/skip pipeline from competing with 4K HDR presentation on the main thread.
    private var lastPlaybackUIUpdateUptime: TimeInterval = 0
    /// Subtitle presentation stays more responsive than the surrounding UI, but does not need to enumerate
    /// tracks and search the embedded subtitle queue ten times per second.
    private var lastSubtitleUpdateUptime: TimeInterval = 0
    private var lastEmbeddedTimelinePlanUptime: TimeInterval = 0
    /// Low-rate health samples make a later report distinguish network starvation from late decoded frames.
    private var lastHealthSampleUptime: TimeInterval = 0
    private var lastHealthBytesRead: Int64 = 0
    private var lastHealthDroppedFrames: UInt32 = 0
    /// A successfully provider-warmed auto-next may use a smaller FIRST fill. As soon as that fill becomes
    /// playable, restore this normal target so any later network refill keeps the stable Vortexo profile.
    private var steadyStateForwardBufferDuration: TimeInterval?
    private var externalSubActive = false
    private let externalRenderer = SubtitleCueRenderer()
    private var hardwareDecodeEnabled = true
    private var muted = false
    private var volume: Float = 1

    var contentIsDolbyVision = false
    var videoSizeMode = UserDefaults.standard.string(forKey: "noiro.videoSize") ?? "original"
    var hardwareDecoding: Bool { hardwareDecodeEnabled }
    var hdrAvailable: Bool { true }
    var playbackPositionSeconds: Double {
        guard let value = layer?.player.currentPlaybackTime, value.isFinite else { return 0 }
        return max(0, value)
    }

    init(host: KSPlayerHostView) {
        self.host = host
        super.init()
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self
        KSOptions.preferredFrame = false
        KSOptions.logLevel = .error
        AVPlayerAudioSession.activateForMovie()
    }

    func loadFile(_ url: URL, headers: [String: String]?, live: Bool) {
        loadFile(url, headers: headers, live: live, warmedNextStartupBuffer: nil)
    }

    /// Fast-start entry used only for an exact next episode whose guarded provider warm completed. The
    /// protocol's normal load stays unchanged for cold starts, source switches, retries, and manual picks.
    func loadFile(_ url: URL, headers: [String: String]?, live: Bool,
                  warmedNextStartupBuffer: TimeInterval?) {
        stopLayerOnly()
        currentURL = url
        currentHeaders = headers
        currentLive = live
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        selectedEmbeddedSubtitleInfo = nil
        selectedEmbeddedSubtitleLanguage = nil
        embeddedTimelineTranslationRunning = false
        embeddedTimelinePlannedThrough = 0
        embeddedTranslatedByCueID = [:]
        lastPlaybackUIUpdateUptime = 0
        lastSubtitleUpdateUptime = 0
        lastEmbeddedTimelinePlanUptime = 0
        lastHealthSampleUptime = 0
        lastHealthBytesRead = 0
        lastHealthDroppedFrames = 0
        lastEmittedDuration = nil
        lastEmittedBufferedEdge = nil
        activeSubtitleParts = []
        publishSubtitle(nil)
        disableExternalSubtitle()

        let options = playbackOptions(for: url, headers: headers, live: live,
                                      warmedNextStartupBuffer: warmedNextStartupBuffer)
        steadyStateForwardBufferDuration = (!url.isFileURL && !live && warmedNextStartupBuffer != nil) ? 14 : nil
        let newLayer = KSPlayerLayer(url: url, options: options, delegate: self)
        newLayer.player.playbackRate = requestedRate
        newLayer.player.playbackVolume = volume
        newLayer.player.isMuted = muted
        newLayer.player.contentMode = contentMode(for: videoSizeMode)
        layer = newLayer
        mount(newLayer.player.view)
        emit(MPVProperty.pausedForCache, true)
        let steady = steadyStateForwardBufferDuration.map { " steady=\(Int($0))s warmedNext=true" } ?? ""
        DiagnosticsLog.log("player", "KSPlayer direct Metal route file=\(url.lastPathComponent) buffer=\(Int(options.preferredForwardBufferDuration))s\(steady)")
    }

    private func playbackOptions(for url: URL, headers: [String: String]?, live: Bool,
                                 warmedNextStartupBuffer: TimeInterval?) -> KSOptions {
        let options = NoiroKSOptions()
        options.hardwareDecode = hardwareDecodeEnabled
        options.asynchronousDecompression = true
        options.display = .plane
        options.videoAdaptable = true
        // Drive CADisplayLink at the video's exact (including fractional) cadence. The local KSPlayer
        // fork preserves 23.976/29.97/59.94 instead of rounding to an integer refresh, preventing the
        // periodic clock correction visible as otherwise-unexplained dropped frames on Apple TV.
        options.preferredFrame = true
        options.matchDisplayCriteria = true
        options.syncDecodeAudio = false
        options.syncDecodeVideo = false
        options.autoSelectEmbedSubtitle = false
        options.isSeekImageSubtitle = true
        options.isAccurateSeek = url.isFileURL
        options.isSeekedAutoPlay = true
        options.registerRemoteControll = false
        options.canStartPictureInPictureAutomaticallyFromInline = false
        options.probesize = 3_000_000
        options.maxAnalyzeDuration = 2_000_000

        if url.isFileURL {
            options.isSecondOpen = true
            options.preferredForwardBufferDuration = 1
            options.maxBufferDuration = 12
        } else {
            // Match Vortexo's stable remote direct-file profile. HLS stays on AVPlayer in the router.
            options.isSecondOpen = false
            let normalForwardBuffer = live ? 8.0 : 14.0
            if !live, let warmedNextStartupBuffer {
                // Five seconds roughly halves the captured ~19-23s cold transition, while retaining enough
                // decoded audio/video for the new episode to begin cleanly. It is restored to 14s after the
                // first fill in player(layer:bufferedCount:consumeTime:), so this is not a weaker refill policy.
                options.preferredForwardBufferDuration = min(normalForwardBuffer,
                                                              max(3, warmedNextStartupBuffer))
            } else {
                options.preferredForwardBufferDuration = normalForwardBuffer
            }
            options.maxBufferDuration = live ? 60 : 90
            options.formatContextOptions["timeout"] = "30000000"
            options.formatContextOptions["rw_timeout"] = "30000000"
            options.formatContextOptions["reconnect"] = "1"
            options.formatContextOptions["reconnect_streamed"] = "1"
            options.formatContextOptions["reconnect_on_network_error"] = "1"
            options.formatContextOptions["reconnect_delay_max"] = "3"
        }
        if let headers, !headers.isEmpty { options.appendHeader(headers) }
        return options
    }

    private func mount(_ view: UIView?) {
        guard let container = host?.videoContainer, let view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }

    func play() { layer?.play() }
    func pause() { layer?.pause() }
    func togglePause() { layer?.state == .paused ? play() : pause() }
    func seek(to seconds: Double) {
        lastPlaybackUIUpdateUptime = 0
        lastSubtitleUpdateUptime = 0
        layer?.seek(time: max(0, seconds), autoPlay: true) { _ in }
    }
    func seek(by seconds: Double) { seek(to: playbackPositionSeconds + seconds) }
    func setSpeed(_ speed: Double) {
        requestedRate = Float(speed)
        layer?.player.playbackRate = requestedRate
    }
    func stop() {
        SubtitleTranslator.shared.cancel()
        embeddedTimelineTranslationRunning = false
        stopLayerOnly()
        disableExternalSubtitle()
        emit(MPVProperty.subText, nil)
    }
    private func stopLayerOnly() {
        steadyStateForwardBufferDuration = nil
        layer?.delegate = nil
        layer?.pause()
        layer?.player.shutdown()
        layer = nil
        host?.videoContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "noiro.videoSize")
        layer?.player.contentMode = contentMode(for: mode)
    }
    private func contentMode(for mode: String) -> UIView.ContentMode {
        switch mode {
        case "zoom", "fill": return .scaleAspectFill
        case "stretch": return .scaleToFill
        default: return .scaleAspectFit
        }
    }

    func tracks(ofType type: String) -> [MPVTrack] {
        guard let player = layer?.player else { return [] }
        let mediaType: AVMediaType = type == "audio" ? .audio : .subtitle
        return player.tracks(mediaType: mediaType).enumerated().map { index, track in
            // KSPlayer marks every text subtitle as enabled while it is discoverable; that flag is
            // decoder availability, not a reliable single-selection value. Keep selection identity in
            // this adapter so the Noiro menu can never check every subtitle row at once.
            let selected = type == "audio"
                ? (selectedAudioIndex.map { $0 == index } ?? track.isEnabled)
                : selectedSubtitleIndex == index
            return MPVTrack(id: index, type: type, title: track.name,
                            lang: track.languageCode ?? "und", selected: selected)
        }
    }

    func setAudioTrack(_ id: Int) {
        guard let player = layer?.player else { return }
        let tracks = player.tracks(mediaType: .audio)
        guard tracks.indices.contains(id) else { return }
        // KSMEPlayer's select(track:) intentionally no-ops when the target is already enabled.
        // Clear every flag first and let KSPlayer perform the actual selection/configuration.
        tracks.forEach { $0.isEnabled = false }
        player.select(track: tracks[id])
        selectedAudioIndex = id
        emit(MPVProperty.trackList, nil)
    }

    func setSubtitleTrack(_ id: Int) {
        guard let player = layer?.player else { return }
        disableExternalSubtitle()
        SubtitleTranslator.shared.cancel()
        embeddedTimelineTranslationRunning = false
        embeddedTimelinePlannedThrough = 0
        embeddedTranslatedByCueID = [:]
        selectedEmbeddedSubtitleInfo = nil
        selectedEmbeddedSubtitleLanguage = nil
        lastEmbeddedTimelinePlanUptime = 0
        lastSubtitleUpdateUptime = 0
        publishPresentedSubtitle(nil)
        let tracks = player.tracks(mediaType: .subtitle)
        tracks.forEach { $0.isEnabled = false }
        guard tracks.indices.contains(id) else {
            selectedSubtitleIndex = nil
            selectedEmbeddedSubtitleInfo = nil
            selectedEmbeddedSubtitleLanguage = nil
            activeSubtitleParts = []
            publishSubtitle(nil)
            emit(MPVProperty.trackList, nil)
            return
        }
        let selected = tracks[id]
        player.select(track: selected)
        selectedSubtitleIndex = id
        selectedEmbeddedSubtitleInfo = selected as? any SubtitleInfo
        selectedEmbeddedSubtitleLanguage = selected.languageCode ?? "und"
        activeSubtitleParts = []
        NSLog("[subs] presenter=shared engine=ks kind=embedded track=%d lang=%@", id,
              selected.languageCode ?? "und")
        emit(MPVProperty.trackList, nil)
    }

    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, shouldLoad: (() -> Bool)?,
                             completion: ((Bool) -> Void)?) {
        guard let remote = URL(string: url) else { completion?(false); return }
        SubtitleFileFetcher.fetch(remote, timeout: timeout) { [weak self] data in
            guard let data else { DispatchQueue.main.async { completion?(false) }; return }
            let cues = SubtitleCueRenderer.parse(data: data)
            guard !cues.isEmpty else { DispatchQueue.main.async { completion?(false) }; return }
            Task { @MainActor in
                guard shouldLoad?() ?? true, let self else { completion?(false); return }
                self.layer?.player.tracks(mediaType: .subtitle).forEach { $0.isEnabled = false }
                self.selectedSubtitleIndex = nil
                self.selectedEmbeddedSubtitleInfo = nil
                self.selectedEmbeddedSubtitleLanguage = nil
                self.activeSubtitleParts = []
                // External subtitles render in KSPlayerHostView's timed overlay. Clear the shared
                // embedded-cue overlay at the exact handoff so its last original/AI cue cannot remain
                // underneath the external track and make playback show two languages at once. This
                // also defeats a late Gemini callback: TVPlayerView only accepts that result while the
                // original cue is still the currently displayed text.
                self.publishSubtitle(nil)
                self.externalRenderer.load(cues: cues)
                self.externalSubActive = true
                // KSPlayer external and embedded subtitles use the same TVPlayerView surface. Keeping the
                // host overlay active here would leave two independent subtitle presenters on screen.
                self.host?.subtitleOverlay.setText(nil)
                let firstCue = cues.first?.start ?? 0
                let lastCue = cues.last?.end ?? 0
                NSLog("[subs] presenter=shared engine=ks kind=external lang=%@ cues=%d clock=%.1f range=%.1f...%.1f",
                      lang, cues.count, self.playbackPositionSeconds, firstCue, lastCue)
                self.updateExternalSubtitle(at: self.playbackPositionSeconds)

                if SubtitleTranslator.shared.shouldTranslate(sourceLanguage: lang, force: false) {
                    let starts = Dictionary(cues.enumerated().map { ($0.offset, $0.element.start) },
                                            uniquingKeysWith: { old, _ in old })
                    SubtitleTranslator.shared.translateTrack(
                        sourceData: data, sourceLanguage: lang, cues: cues,
                        resumeSeconds: self.playbackPositionSeconds
                    ) { [weak self] translated in
                        let byStart = Dictionary(
                            translated.compactMap { index, text -> (TimeInterval, String)? in
                                starts[index].map { ($0, text) }
                            }, uniquingKeysWith: { _, new in new })
                        self?.externalRenderer.applyTranslations(byStart)
                        if self?.externalSubActive == true {
                            self?.updateExternalSubtitle(at: self?.playbackPositionSeconds ?? 0)
                        }
                    }
                }
                completion?(true)
            }
        }
    }

    func setSubDelay(_ seconds: Double) {
        subDelay = seconds
        externalRenderer.offset = seconds
        if externalSubActive { updateExternalSubtitle(at: playbackPositionSeconds) }
    }
    func setAudioDelay(_ seconds: Double) {}
    // The low-level KSPlayer view has no native subtitle label; embedded cues are always drawn by Noiro.
    func setSubVisibility(_ visible: Bool) {}
    func setSubtitleVerticalOffset(_ points: Double) { host?.subtitleOverlay.setVerticalOffset(points) }
    func applySubtitleStyle() { host?.subtitleOverlay.applyStyle() }
    func currentSubDelaySeconds() -> Double { subDelay }

    func containerFrameRate() -> Double { Double(layer?.player.nominalFrameRate ?? 0) }
    func mediaDurationSeconds() -> Double {
        guard let duration = layer?.player.duration, duration.isFinite else { return 0 }
        return duration
    }
    func chapters() -> [MPVChapter] {
        layer?.player.chapters.map { MPVChapter(title: $0.title, start: $0.start) } ?? []
    }
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String) {
        let size = layer?.player.naturalSize ?? .zero
        return (Int(size.width), Int(size.height), "")
    }
    func playbackStats() -> [(String, String)] {
        guard let info = layer?.player.dynamicInfo else { return [] }
        var rows: [(String, String)] = []
        let size = layer?.player.naturalSize ?? .zero
        if size.height > 0 { rows.append(("Resolution", "\(Int(size.width))×\(Int(size.height))")) }
        if info.videoBitrate > 0 { rows.append(("Video bitrate", "\(info.videoBitrate / 1_000) kbps")) }
        if info.displayFPS > 0 { rows.append(("Display FPS", String(format: "%.2f", info.displayFPS))) }
        if info.droppedVideoFrameCount > 0 { rows.append(("Dropped frames", "\(info.droppedVideoFrameCount)")) }
        return rows
    }

    func setHardwareDecoding(_ on: Bool) { hardwareDecodeEnabled = on }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}
    // Avoid any periodic GPU readback during 4K playback; community trickplay remains server/cache based.
    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) { completion(nil) }
    func setVolume(_ volume0to100: Double) {
        volume = Float(max(0, min(100, volume0to100)) / 100)
        layer?.player.playbackVolume = volume
    }
    func setMuted(_ muted: Bool) {
        self.muted = muted
        layer?.player.isMuted = muted
    }

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer else { return }
        let buffering: Bool
        let probeState: String
        switch state {
        case .preparing, .buffering:
            buffering = true
            probeState = state.description
            emit(MPVProperty.pausedForCache, true)
        case .readyToPlay, .bufferFinished:
            buffering = false
            probeState = "playing"
            mount(layer.player.view)
            emit(MPVProperty.pausedForCache, false)
            emit(MPVProperty.duration, layer.player.duration)
            emit(MPVProperty.seekable, layer.player.seekable)
            emit(MPVProperty.trackList, nil)
            emit(MPVProperty.pause, false)
        case .paused:
            buffering = false
            probeState = "paused"
            emit(MPVProperty.pause, true)
        case .playedToTheEnd:
            buffering = false
            probeState = "ended"
            emit(MPVProperty.endFileEof, nil)
        case .error:
            buffering = false
            probeState = "error"
            emit(MPVProperty.endFileError, "KSPlayer failed to play this source")
        case .initialized:
            buffering = false
            probeState = "initialized"
        }
        VXProbeState.shared.setPlayer(state: probeState, engine: "ksplayer", buffering: buffering)
        logPlaybackEvent("KSPlayer state=\(state.description) \(healthSummary(for: layer))")
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.layer else { return }
        let uptime = ProcessInfo.processInfo.systemUptime

        // Captions retain a 5 Hz clock (within 200 ms of the decoded cue), independent of the heavier
        // playback UI cadence below. Track identity is cached at selection time, so this hot path no longer
        // re-enumerates every audio/subtitle stream in a large MKV on every tick.
        if lastSubtitleUpdateUptime == 0 || uptime - lastSubtitleUpdateUptime >= 0.2 {
            lastSubtitleUpdateUptime = uptime
            externalSubActive ? updateExternalSubtitle(at: currentTime) : updateEmbeddedSubtitle(at: currentTime)
        }

        samplePlaybackHealth(for: layer, uptime: uptime)

        // Match Vortexo's 500 ms observer. The decoder and Metal display link remain independent and continue
        // at the content/display frame rate; only Noiro's progress, persistence, skip and Up Next work is gated.
        guard lastPlaybackUIUpdateUptime == 0 || uptime - lastPlaybackUIUpdateUptime >= 0.5 else { return }
        lastPlaybackUIUpdateUptime = uptime
        emit(MPVProperty.timePos, currentTime)
        VXProbeState.shared.setPlayer(
            pos: currentTime.isFinite ? Int(currentTime) : 0,
            dur: totalTime.isFinite && totalTime > 0 ? Int(totalTime) : nil,
            engine: "ksplayer"
        )
        // KSPlayer calls this delegate every 100 ms. A duration event is expensive in Noiro: it
        // rebuilds the subtitle fingerprint and refreshes pooled/skip metadata. Emitting an unchanged
        // duration on every clock tick caused that work to run ten times per second during playback.
        if totalTime.isFinite, totalTime > 0,
           lastEmittedDuration.map({ abs($0 - totalTime) >= 0.5 }) ?? true {
            lastEmittedDuration = totalTime
            emit(MPVProperty.duration, totalTime)
        }
        // `playableTime` is already an absolute media timestamp in both KSMEPlayer and KSAVPlayer. Adding
        // currentTime again overstated the buffer and could paint a completed progress line prematurely.
        let bufferedEdge = Self.bufferedEdge(
            currentTime: currentTime, totalTime: totalTime, playableTime: layer.player.playableTime
        )
        if bufferedEdge.isFinite,
           lastEmittedBufferedEdge.map({ abs($0 - bufferedEdge) >= 0.5 }) ?? true {
            lastEmittedBufferedEdge = bufferedEdge
            emit(MPVProperty.demuxerCacheTime, bufferedEdge)
        }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer else { return }
        if let error { emit(MPVProperty.endFileError, error.localizedDescription) }
        else { emit(MPVProperty.endFileEof, nil) }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        guard layer === self.layer else { return }
        let fillTime = String(format: "%.2f", consumeTime)
        logPlaybackEvent(
            "KSPlayer buffer-filled count=\(bufferedCount) fillTime=\(fillTime)s "
                + healthSummary(for: layer)
        )
        if bufferedCount == 0, let steady = steadyStateForwardBufferDuration {
            layer.options.preferredForwardBufferDuration = steady
            steadyStateForwardBufferDuration = nil
            DiagnosticsLog.log("player", "KSPlayer warmed-next first fill complete; refill buffer restored to \(Int(steady))s")
        }
    }

    private func updateEmbeddedSubtitle(at clock: TimeInterval) {
        guard let selectedSubtitleIndex, let info = selectedEmbeddedSubtitleInfo else {
            publishSubtitle(nil)
            return
        }
        let shifted = clock - subDelay
        pretranslateEmbeddedTimeline(info: info, trackIndex: selectedSubtitleIndex, after: shifted)
        let decoded = info.search(for: shifted)
        if !decoded.isEmpty { activeSubtitleParts = decoded }
        activeSubtitleParts = activeSubtitleParts.filter { $0 == shifted }
        let original = activeSubtitleParts.compactMap {
            $0.text?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        let translationEnabled = SubtitleTranslator.shared.shouldTranslate(
            sourceLanguage: selectedEmbeddedSubtitleLanguage,
            force: false
        )
        let translated = translationEnabled ? activeSubtitleParts.compactMap { part -> String? in
            let source = part.text?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !source.isEmpty, let value = embeddedTranslatedByCueID[Self.subtitleCueID(part.start)] else { return nil }
            let targetOnly = SubtitleTranslationPresentationPolicy.displayedText(
                originalText: source, translatedText: value
            )
            return targetOnly.isEmpty ? nil : targetOnly
        }.joined(separator: "\n") : ""

        if !translated.isEmpty {
            publishSubtitle(nil)
            publishPresentedSubtitle(translated)
        } else {
            publishPresentedSubtitle(nil)
            publishSubtitle(original.isEmpty ? nil : original)
        }
    }

    /// Translate every decoded cue currently available ahead of the playhead. KSPlayer's embedded subtitle
    /// queue holds up to 255 frames; after a window completes, playback naturally exposes the next window,
    /// so this progressively builds and persists the complete episode/movie translation without waiting for
    /// each line to reach the screen.
    private func pretranslateEmbeddedTimeline(info: any SubtitleInfo, trackIndex: Int, after clock: TimeInterval) {
        guard !embeddedTimelineTranslationRunning else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        // Snapshotting up to 255 queued cues is useful for whole-title translation, but doing it on every
        // 100 ms player tick needlessly competes with HDR presentation. New queue windows appear slowly, so
        // a two-second planning cadence remains comfortably ahead of playback.
        guard lastEmbeddedTimelinePlanUptime == 0 || uptime - lastEmbeddedTimelinePlanUptime >= 2 else { return }
        lastEmbeddedTimelinePlanUptime = uptime
        let sourceLanguage = selectedEmbeddedSubtitleLanguage
        guard SubtitleTranslator.shared.shouldTranslate(sourceLanguage: sourceLanguage, force: false) else { return }

        let parts = info.upcomingParts(after: clock, limit: 255).filter {
            guard let text = $0.text?.string.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty && $0.start.isFinite && $0.end.isFinite
        }
        guard let lastEnd = parts.last?.end,
              lastEnd > embeddedTimelinePlannedThrough + 1 else { return }

        var seen = Set<Int>()
        let cues = parts.compactMap { part -> SubtitleTranslationCue? in
            let id = Self.subtitleCueID(part.start)
            guard seen.insert(id).inserted,
                  let text = part.text?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return SubtitleTranslationCue(id: id, text: text)
        }
        guard !cues.isEmpty else { return }

        embeddedTimelineTranslationRunning = true
        embeddedTimelinePlannedThrough = lastEnd
        let stableURL = currentURL.flatMap { url -> String? in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            return components?.string
        } ?? currentURL?.absoluteString ?? "unknown"
        let seed = Data("\(stableURL)|subtitle-track:\(trackIndex)".utf8)
        SubtitleTranslator.shared.translateEmbeddedTimeline(
            cacheSeed: seed, sourceLanguage: sourceLanguage, cues: cues
        ) { [weak self] translated in
            self?.embeddedTranslatedByCueID.merge(translated) { _, new in new }
        } onComplete: { [weak self] in
            self?.embeddedTimelineTranslationRunning = false
        }
    }

    private static func bufferedEdge(currentTime: TimeInterval, totalTime: TimeInterval,
                                     playableTime: TimeInterval) -> TimeInterval {
        guard playableTime.isFinite else { return currentTime }
        let edge = max(currentTime, playableTime)
        guard totalTime.isFinite, totalTime > 0 else { return edge }
        return min(totalTime, edge)
    }

    private func healthSummary(for layer: KSPlayerLayer) -> String {
        let player = layer.player
        let current = player.currentPlaybackTime
        let ahead = max(0, player.playableTime - current)
        let info = player.dynamicInfo
        let fps = info?.displayFPS ?? 0
        let dropped = info?.droppedVideoFrameCount ?? 0
        return String(
            format: "pos=%.1fs bufferAhead=%.1fs displayFPS=%.2f dropped=%u",
            current.isFinite ? current : 0, ahead.isFinite ? ahead : 0, fps, dropped
        )
    }

    private func samplePlaybackHealth(for layer: KSPlayerLayer, uptime: TimeInterval) {
        guard lastHealthSampleUptime == 0 || uptime - lastHealthSampleUptime >= 5 else { return }
        let player = layer.player
        let info = player.dynamicInfo
        let bytesRead = info?.bytesRead ?? 0
        let dropped = info?.droppedVideoFrameCount ?? 0
        let current = player.currentPlaybackTime
        let ahead = max(0, player.playableTime - current)

        guard lastHealthSampleUptime > 0 else {
            lastHealthSampleUptime = uptime
            lastHealthBytesRead = bytesRead
            lastHealthDroppedFrames = dropped
            return
        }

        let elapsed = max(0.001, uptime - lastHealthSampleUptime)
        let byteDelta = max(Int64(0), bytesRead - lastHealthBytesRead)
        let throughputMbps = Double(byteDelta) * 8 / elapsed / 1_000_000
        let droppedDelta = dropped >= lastHealthDroppedFrames ? dropped - lastHealthDroppedFrames : dropped
        let message = String(
            format: "KSPlayer health pos=%.1fs bufferAhead=%.1fs read=%.2fMbps displayFPS=%.2f dropped=%u (+%u)",
            current.isFinite ? current : 0, ahead.isFinite ? ahead : 0, throughputMbps,
            info?.displayFPS ?? 0, dropped, droppedDelta
        )

        // Healthy samples are available when Diagnostic Logging is enabled. Starvation or newly dropped
        // frames are always persisted and mirrored to Console so the next report contains the actual cause.
        if droppedDelta > 0 || (layer.state.isPlaying && ahead < 3) {
            logPlaybackEvent(message)
        } else {
            VXProbe.log("player", message)
        }
        lastHealthSampleUptime = uptime
        lastHealthBytesRead = bytesRead
        lastHealthDroppedFrames = dropped
    }

    private func logPlaybackEvent(_ message: String) {
        DiagnosticsLog.log("player", message)
        // DiagnosticsLog mirrors to Console through VXProbe when probing is enabled. Keep a single Console
        // copy when it is off too, so Xcode captures buffering/drop evidence without a settings dependency.
        if !VXProbe.enabled { NSLog("[player] %@", message) }
    }

    private static func subtitleCueID(_ start: TimeInterval) -> Int {
        Int((start * 1000).rounded())
    }

    private func publishSubtitle(_ text: String?) {
        guard text != lastSubtitleText else { return }
        lastSubtitleText = text
        emit(MPVProperty.subText, text)
    }

    private func updateExternalSubtitle(at clock: TimeInterval) {
        publishPresentedSubtitle(externalRenderer.activeText(atClock: clock))
    }

    private func publishPresentedSubtitle(_ text: String?) {
        guard text != lastPresentedSubtitleText else { return }
        lastPresentedSubtitleText = text
        emit(MPVProperty.presentedSubText, text)
    }

    private func disableExternalSubtitle() {
        externalSubActive = false
        externalRenderer.clear()
        host?.subtitleOverlay.setText(nil)
        publishPresentedSubtitle(nil)
    }

    private func emit(_ property: String, _ data: Any?) {
        playDelegate?.propertyChange(propertyName: property, data: data)
    }
}
#endif
