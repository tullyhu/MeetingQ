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

import XCTest
@testable import MeetingQCore

/// Tests reference the numbered edge cases in docs/speaker_diarization_spec.md.
final class SpeakerClustererTests: XCTestCase {
    /// 192-d unit vector pointing mostly along basis vector `axis`.
    private func emb(_ axis: Int, noise: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 192)
        v[axis] = 1
        if noise > 0 { v[(axis + 1) % 192] = noise }
        return v
    }

    // MARK: Duration gates

    func testSubSecondSegmentsAreSkipped() {
        for d in [0.0, 0.05, 0.1, 0.5, 0.99] {
            XCTAssertEqual(SpeakerClusterer.identifyDecision(durationSeconds: d), .skip, "\(d)s must abstain")
        }
    }

    func testOneToTwoSecondsMatchOnly() {
        for d in [1.0, 1.5, 1.999] {
            XCTAssertEqual(SpeakerClusterer.identifyDecision(durationSeconds: d), .matchOnly)
        }
    }

    func testTwoSecondsAndAboveLearn() {
        for d in [2.0, 3.5, 60.0] {
            XCTAssertEqual(SpeakerClusterer.identifyDecision(durationSeconds: d), .matchAndLearn)
        }
    }

    func testNonFiniteDurationFailsClosed() {
        XCTAssertEqual(SpeakerClusterer.identifyDecision(durationSeconds: .nan), .skip)
        XCTAssertEqual(SpeakerClusterer.identifyDecision(durationSeconds: -.infinity), .skip)
    }

    // MARK: Clustering

    func testDistinctVoicesFormSeparateClusters() {
        var c = SpeakerClusterer()
        let a = c.process(embedding: emb(0), durationSeconds: 3)
        let b = c.process(embedding: emb(50), durationSeconds: 3)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(c.clusters.count, 2)
    }

    func testSameVoiceMatchesSameCluster() {
        var c = SpeakerClusterer()
        let first = c.process(embedding: emb(0), durationSeconds: 3)
        let again = c.process(embedding: emb(0, noise: 0.01), durationSeconds: 3)
        XCTAssertEqual(first, again)
        XCTAssertEqual(c.clusters.count, 1)
    }

    func testMatchOnlySegmentsNeverCreateOrTeach() {
        var c = SpeakerClusterer()
        // 1.5s segment: may match but must not create.
        XCTAssertNil(c.process(embedding: emb(0), durationSeconds: 1.5))
        XCTAssertEqual(c.clusters.count, 0)

        // Establish a cluster, then confirm a 1.5s match does not add samples.
        _ = c.process(embedding: emb(0), durationSeconds: 3)
        let samplesBefore = c.clusters[0].samples.count
        XCTAssertEqual(c.process(embedding: emb(0, noise: 0.01), durationSeconds: 1.5), c.clusters[0].id)
        XCTAssertEqual(c.clusters[0].samples.count, samplesBefore)
    }

    /// Spec case R6: beyond maxClusters, force-merge to nearest instead of creating.
    func testClusterCapacityForceMerges() {
        var c = SpeakerClusterer(maxClusters: 2)
        _ = c.process(embedding: emb(0), durationSeconds: 3)
        _ = c.process(embedding: emb(50), durationSeconds: 3)
        let third = c.process(embedding: emb(100), durationSeconds: 3)
        XCTAssertNotNil(third)
        XCTAssertEqual(c.clusters.count, 2, "must not exceed maxClusters")
    }

    /// Spec case R5: a lone cluster means "no separation" — caller keeps 对方.
    func testStableClustersRequireTwoSamples() {
        var c = SpeakerClusterer()
        _ = c.process(embedding: emb(0), durationSeconds: 3)
        XCTAssertEqual(c.stableClusters.count, 0)
        _ = c.process(embedding: emb(0, noise: 0.01), durationSeconds: 3)
        XCTAssertEqual(c.stableClusters.count, 1)
        XCTAssertTrue(c.isLiveLabelable(c.clusters[0].id))
    }

    func testResetClearsClusters() {
        var c = SpeakerClusterer()
        _ = c.process(embedding: emb(0), durationSeconds: 3)
        c.reset()
        XCTAssertTrue(c.clusters.isEmpty)
    }

    // MARK: Library matching

    func testLibraryMatchAboveThreshold() {
        let library: [(id: Int64, centroid: [Float])] = [(1, emb(0)), (2, emb(50))]
        XCTAssertEqual(SpeakerClusterer.bestLibraryMatch(embedding: emb(0, noise: 0.01), against: library, threshold: 0.75), 1)
        XCTAssertNil(SpeakerClusterer.bestLibraryMatch(embedding: emb(100), against: library, threshold: 0.75))
    }

    func testLibraryMatchEmptyLibrary() {
        XCTAssertNil(SpeakerClusterer.bestLibraryMatch(embedding: emb(0), against: [], threshold: 0.75))
    }
}
