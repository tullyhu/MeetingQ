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

import Foundation

/// Pure, model-free speaker clustering logic: duration gates, centroid +
/// sample matching, capacity force-merge. Extracted from
/// SpeakerDiarizationService (which supplies CAM++ embeddings) so the whole
/// decision surface is unit-testable without CoreML models.
/// See docs/speaker_diarization_spec.md (cases R5, R6).
public struct SpeakerClusterer: Sendable {
    public static let minIdentifySeconds: Double = 1.0
    public static let minLearnSeconds: Double = 2.0
    public static let maxSamplesPerCluster = 10
    public static let minSamplesForLiveLabel = 2

    public enum IdentifyDecision: Sendable, Equatable {
        case skip, matchOnly, matchAndLearn
    }

    public static func identifyDecision(durationSeconds: Double) -> IdentifyDecision {
        guard durationSeconds.isFinite, durationSeconds >= minIdentifySeconds else { return .skip }
        return durationSeconds >= minLearnSeconds ? .matchAndLearn : .matchOnly
    }

    public struct Cluster: Sendable, Equatable {
        public let id: Int
        public internal(set) var centroid: [Float]
        public internal(set) var samples: [[Float]]
        public internal(set) var lastHeardAt: Date
        public var learnCount: Int { samples.count }
    }

    public let matchThreshold: Float
    public let maxClusters: Int
    public private(set) var clusters: [Cluster] = []

    public init(matchThreshold: Float = 0.72, maxClusters: Int = 6) {
        self.matchThreshold = matchThreshold
        self.maxClusters = maxClusters
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Feed one embedding with its real speech duration.
    /// - Returns: cluster id when matched/created, nil when skipped.
    @discardableResult
    public mutating func process(embedding: [Float], durationSeconds: Double, at time: Date = Date()) -> Int? {
        switch Self.identifyDecision(durationSeconds: durationSeconds) {
        case .skip:
            return nil
        case .matchOnly:
            return bestMatch(for: embedding)
        case .matchAndLearn:
            if let id = bestMatch(for: embedding) {
                learn(embedding, into: id, at: time)
                return id
            }
            if clusters.count < maxClusters {
                let id = (clusters.map(\.id).max() ?? 0) + 1
                clusters.append(Cluster(id: id, centroid: embedding, samples: [embedding], lastHeardAt: time))
                return id
            }
            if let id = nearestCluster(to: embedding) {
                learn(embedding, into: id, at: time)
                return id
            }
            return nil
        }
    }

    /// Clusters stable enough for live labels / library persistence.
    public var stableClusters: [Cluster] {
        clusters.filter { $0.learnCount >= Self.minSamplesForLiveLabel }
    }

    public func isLiveLabelable(_ clusterId: Int) -> Bool {
        clusters.first { $0.id == clusterId }?.learnCount ?? 0 >= Self.minSamplesForLiveLabel
    }

    /// Best library match above `threshold` (lookup only, never writes).
    public static func bestLibraryMatch(embedding: [Float],
                                        against library: [(id: Int64, centroid: [Float])],
                                        threshold: Float) -> Int64? {
        var bestId: Int64? = nil
        var best = threshold
        for entry in library {
            let sim = cosine(embedding, entry.centroid)
            if sim > best { best = sim; bestId = entry.id }
        }
        return bestId
    }

    public mutating func reset() { clusters = [] }

    // MARK: - Internals

    private func bestMatch(for embedding: [Float]) -> Int? {
        var bestId: Int? = nil
        var best = matchThreshold
        for c in clusters {
            var sim = Self.cosine(embedding, c.centroid)
            for s in c.samples { sim = max(sim, Self.cosine(embedding, s)) }
            if sim > best { best = sim; bestId = c.id }
        }
        return bestId
    }

    private func nearestCluster(to embedding: [Float]) -> Int? {
        clusters.max { Self.cosine(embedding, $0.centroid) < Self.cosine(embedding, $1.centroid) }?.id
    }

    private mutating func learn(_ embedding: [Float], into id: Int, at time: Date) {
        guard let idx = clusters.firstIndex(where: { $0.id == id }) else { return }
        var c = clusters[idx]
        let n = Float(c.samples.count)
        c.centroid = zip(c.centroid, embedding).map { ($0 * n + $1) / (n + 1) }
        c.samples.append(embedding)
        if c.samples.count > Self.maxSamplesPerCluster { c.samples.removeFirst() }
        c.lastHeardAt = time
        clusters[idx] = c
    }
}
