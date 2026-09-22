//
//  EmbedDataSouce.swift
//  KSPlayer-7de52535
//
//  Created by kintan on 2018/8/7.
//
import Foundation
import Libavcodec
import Libavutil

extension FFmpegAssetTrack: SubtitleInfo {
    public var subtitleID: String {
        String(trackID)
    }
}

extension FFmpegAssetTrack: KSSubtitleProtocol {
    public func search(for time: TimeInterval) -> [SubtitlePart] {
        // Embedded subtitle frames are ordered by time, so we can safely drain the
        // contiguous prefix of expired/current entries. Removing only "current"
        // matches leaves old expired frames stranded in the ring buffer, which can
        // eventually trip CircularBuffer's occupancy assertions after wraparound.
        let consumedFrames = subtitle?.outputRenderQueue.search { item -> Bool in
            item.part < time || item.part == time
        } ?? []

        return consumedFrames
            .map(\.part)
            .filter { $0 == time }
    }

    public func upcomingParts(after time: TimeInterval, limit: Int) -> [SubtitlePart] {
        guard limit > 0 else { return [] }
        return subtitle?.outputRenderQueue
            .snapshot(limit: limit) { $0.part.start > time }
            .map(\.part) ?? []
    }
}

extension KSMEPlayer: SubtitleDataSouce {
    public var infos: [any SubtitleInfo] {
        tracks(mediaType: .subtitle).compactMap { $0 as? (any SubtitleInfo) }
    }
}
