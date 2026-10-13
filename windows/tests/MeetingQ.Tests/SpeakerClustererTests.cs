using MeetingQ.Services;
using Xunit;

namespace MeetingQ.Tests;

/// <summary>
/// Mirrors the macOS SpeakerClustererTests. Cases reference
/// docs/speaker_diarization_spec.md (R5/R6) and the duration gates.
/// </summary>
public class SpeakerClustererTests
{
    /// <summary>192-d unit vector along basis vector <paramref name="axis"/>.</summary>
    private static float[] Emb(int axis, float noise = 0)
    {
        var v = new float[192];
        v[axis] = 1;
        if (noise > 0) v[(axis + 1) % 192] = noise;
        return v;
    }

    // ── Duration gates ──

    [Theory]
    [InlineData(0.0)]
    [InlineData(0.05)]
    [InlineData(0.5)]
    [InlineData(0.99)]
    public void SubSecondSegmentsAreSkipped(double d) =>
        Assert.Equal(SpeakerClusterer.IdentifyDecision.Skip, SpeakerClusterer.Decide(d));

    [Theory]
    [InlineData(1.0)]
    [InlineData(1.5)]
    [InlineData(1.999)]
    public void OneToTwoSecondsMatchOnly(double d) =>
        Assert.Equal(SpeakerClusterer.IdentifyDecision.MatchOnly, SpeakerClusterer.Decide(d));

    [Theory]
    [InlineData(2.0)]
    [InlineData(3.5)]
    [InlineData(60.0)]
    public void TwoSecondsAndAboveLearn(double d) =>
        Assert.Equal(SpeakerClusterer.IdentifyDecision.MatchAndLearn, SpeakerClusterer.Decide(d));

    [Fact]
    public void NonFiniteDurationFailsClosed()
    {
        Assert.Equal(SpeakerClusterer.IdentifyDecision.Skip, SpeakerClusterer.Decide(double.NaN));
        Assert.Equal(SpeakerClusterer.IdentifyDecision.Skip, SpeakerClusterer.Decide(double.NegativeInfinity));
    }

    // ── Clustering ──

    [Fact]
    public void DistinctVoicesFormSeparateClusters()
    {
        var c = new SpeakerClusterer();
        var a = c.Process(Emb(0), 3);
        var b = c.Process(Emb(50), 3);
        Assert.NotNull(a);
        Assert.NotNull(b);
        Assert.NotEqual(a, b);
        Assert.Equal(2, c.Clusters.Count);
    }

    [Fact]
    public void SameVoiceMatchesSameCluster()
    {
        var c = new SpeakerClusterer();
        var first = c.Process(Emb(0), 3);
        var again = c.Process(Emb(0, noise: 0.01f), 3);
        Assert.Equal(first, again);
        Assert.Single(c.Clusters);
    }

    [Fact]
    public void MatchOnlySegmentsNeverCreateOrTeach()
    {
        var c = new SpeakerClusterer();
        Assert.Null(c.Process(Emb(0), 1.5));
        Assert.Empty(c.Clusters);

        _ = c.Process(Emb(0), 3);
        var before = c.Clusters[0].Samples.Count;
        Assert.Equal(c.Clusters[0].Id, c.Process(Emb(0, noise: 0.01f), 1.5));
        Assert.Equal(before, c.Clusters[0].Samples.Count);
    }

    /// <summary>Spec R6: beyond maxClusters, force-merge to nearest instead of creating.</summary>
    [Fact]
    public void ClusterCapacityForceMerges()
    {
        var c = new SpeakerClusterer(maxClusters: 2);
        _ = c.Process(Emb(0), 3);
        _ = c.Process(Emb(50), 3);
        var third = c.Process(Emb(100), 3);
        Assert.NotNull(third);
        Assert.Equal(2, c.Clusters.Count);
    }

    /// <summary>Spec R5: a lone cluster means "no separation" — caller keeps 对方.</summary>
    [Fact]
    public void StableClustersRequireTwoSamples()
    {
        var c = new SpeakerClusterer();
        _ = c.Process(Emb(0), 3);
        Assert.Empty(c.StableClusters);
        _ = c.Process(Emb(0, noise: 0.01f), 3);
        Assert.Single(c.StableClusters);
        Assert.True(c.IsLiveLabelable(c.Clusters[0].Id));
    }

    [Fact]
    public void ResetClearsClusters()
    {
        var c = new SpeakerClusterer();
        _ = c.Process(Emb(0), 3);
        c.Reset();
        Assert.Empty(c.Clusters);
    }

    // ── Library matching ──

    [Fact]
    public void LibraryMatchAboveThreshold()
    {
        var library = new List<(long Id, float[] Centroid)> { (1, Emb(0)), (2, Emb(50)) };
        Assert.Equal(1, SpeakerClusterer.BestLibraryMatch(Emb(0, noise: 0.01f), library, 0.75f));
        Assert.Null(SpeakerClusterer.BestLibraryMatch(Emb(100), library, 0.75f));
    }

    [Fact]
    public void LibraryMatchEmptyLibrary() =>
        Assert.Null(SpeakerClusterer.BestLibraryMatch(Emb(0), new List<(long, float[])>(), 0.75f));
}
