// MeetingQ - 本地优先的 AI 会议助手（被叫提醒 + 智能纪要）
// Copyright (C) 2026 MeetingQ contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import FluidAudio
import Foundation
import MeetingQCore

/// Splits the remote (system-audio) track into per-person speaker clusters
/// using on-device CAM++ speaker embeddings (192-d, fp16, ANE via FluidAudio).
///
/// Thin wrapper: model loading + embedding extraction here, all clustering
/// decisions live in the pure `SpeakerClusterer` (unit-tested).
/// See docs/speaker_diarization_spec.md.
///
/// Every failure (model missing, CoreML error) surfaces as `nil` results so
/// the caller silently falls back to the single "对方" label.
public actor SpeakerDiarizationService {
    public typealias IdentifyDecision = SpeakerClusterer.IdentifyDecision
    public typealias Cluster = SpeakerClusterer.Cluster

    public static let minIdentifySeconds = SpeakerClusterer.minIdentifySeconds
    public static let minLearnSeconds = SpeakerClusterer.minLearnSeconds
    public static let minSamplesForLiveLabel = SpeakerClusterer.minSamplesForLiveLabel

    public static func identifyDecision(durationSeconds: Double) -> IdentifyDecision {
        SpeakerClusterer.identifyDecision(durationSeconds: durationSeconds)
    }

    public enum State: Sendable {
        case idle, preparing, ready, failed
    }

    public private(set) var state: State = .idle

    private var embedder: CampPlusEmbedder?
    private var clusterer = SpeakerClusterer()

    public init() {}

    /// Downloads (first time only) and loads the CAM++ models. Throws on
    /// failure — caller should turn the feature toggle back off.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        state = .preparing
        do {
            embedder = try await CampPlusEmbedder.load { p in
                progress?(p.fractionCompleted)
            }
            state = .ready
        } catch {
            state = .failed
            throw error
        }
    }

    public var isReady: Bool { state == .ready && embedder != nil }

    public var clusters: [Cluster] { clusterer.clusters }

    /// Process one VAD-delimited speech segment from the remote track.
    /// - Returns: cluster id when matched/created, nil when skipped or failed.
    @discardableResult
    public func processSegment(samples: [Float], at time: Date = Date()) async -> Int? {
        guard let embedder else { return nil }
        let duration = Double(samples.count) / 16000.0
        guard SpeakerClusterer.identifyDecision(durationSeconds: duration) != .skip else { return nil }

        let embedding: [Float]
        do {
            embedding = try await embedder.embed(audio: samples)
        } catch {
            return nil
        }
        guard embedding.count == CampPlusEmbedder.embeddingDim else { return nil }
        return clusterer.process(embedding: embedding, durationSeconds: duration, at: time)
    }

    /// Clear all meeting-scoped clusters. Called at meeting end, after the
    /// caller has persisted stable clusters to the library.
    public func resetClusters() {
        clusterer.reset()
    }

    /// Snapshot of clusters stable enough to persist (≥2 learnable samples).
    public var stableClusters: [Cluster] { clusterer.stableClusters }

    /// Whether `clusterId` has enough evidence to show a live label.
    public func isLiveLabelable(_ clusterId: Int) -> Bool {
        clusterer.isLiveLabelable(clusterId)
    }

    /// Centroid of a cluster, for live matching against the voiceprint library.
    public func centroid(of clusterId: Int) -> [Float]? {
        clusterer.clusters.first { $0.id == clusterId }?.centroid
    }

    /// Best library match above `threshold`, purely a lookup — never writes.
    public nonisolated static func bestLibraryMatch(embedding: [Float],
                                                    against library: [(id: Int64, centroid: [Float])],
                                                    threshold: Float) -> Int64? {
        SpeakerClusterer.bestLibraryMatch(embedding: embedding, against: library, threshold: threshold)
    }
}
