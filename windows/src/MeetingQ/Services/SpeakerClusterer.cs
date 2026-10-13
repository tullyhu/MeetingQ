namespace MeetingQ.Services;

/// <summary>
/// Pure, model-free speaker clustering logic: duration gates, centroid + sample
/// matching, capacity force-merge. Ported from macOS MeetingQCore/SpeakerClusterer.swift
/// so both platforms share the same decision surface (docs/speaker_diarization_spec.md,
/// cases R5/R6).
///
/// <see cref="OnlineSpeakerCluster"/> remains for the offline refinement pass;
/// this type is the live-meeting clusterer.
/// </summary>
public sealed class SpeakerClusterer
{
    public const double MinIdentifySeconds = 1.0;
    public const double MinLearnSeconds = 2.0;
    public const int MaxSamplesPerCluster = 10;
    public const int MinSamplesForLiveLabel = 2;

    public enum IdentifyDecision { Skip, MatchOnly, MatchAndLearn }

    public static IdentifyDecision Decide(double durationSeconds)
    {
        if (!double.IsFinite(durationSeconds) || durationSeconds < MinIdentifySeconds)
            return IdentifyDecision.Skip;
        return durationSeconds >= MinLearnSeconds
            ? IdentifyDecision.MatchAndLearn
            : IdentifyDecision.MatchOnly;
    }

    public sealed class Cluster
    {
        public int Id { get; }
        public float[] Centroid { get; internal set; }
        public List<float[]> Samples { get; } = new();
        public DateTime LastHeardAt { get; internal set; }
        public int LearnCount => Samples.Count;

        public Cluster(int id, float[] centroid, DateTime heardAt)
        {
            Id = id;
            Centroid = centroid;
            Samples.Add(centroid);
            LastHeardAt = heardAt;
        }
    }

    private readonly float _matchThreshold;
    private readonly int _maxClusters;
    private readonly List<Cluster> _clusters = new();

    public IReadOnlyList<Cluster> Clusters => _clusters;

    public SpeakerClusterer(float matchThreshold = 0.72f, int maxClusters = 6)
    {
        _matchThreshold = matchThreshold;
        _maxClusters = maxClusters;
    }

    public static float Cosine(float[] a, float[] b)
    {
        // Embeddings are L2-normalized upstream; dot product IS cosine.
        float dot = 0;
        for (var i = 0; i < a.Length && i < b.Length; i++) dot += a[i] * b[i];
        return dot;
    }

    /// <summary>
    /// Feed one embedding with its real speech duration.
    /// Returns the cluster id when matched/created, null when skipped.
    /// </summary>
    public int? Process(float[] embedding, double durationSeconds, DateTime? at = null)
    {
        var now = at ?? DateTime.Now;
        switch (Decide(durationSeconds))
        {
            case IdentifyDecision.Skip:
                return null;
            case IdentifyDecision.MatchOnly:
                return BestMatch(embedding);
            case IdentifyDecision.MatchAndLearn:
            {
                var matched = BestMatch(embedding);
                if (matched is int mid)
                {
                    Learn(embedding, mid, now);
                    return mid;
                }
                if (_clusters.Count < _maxClusters)
                {
                    var id = _clusters.Count == 0 ? 1 : _clusters.Max(c => c.Id) + 1;
                    _clusters.Add(new Cluster(id, embedding, now));
                    return id;
                }
                // Spec R6: beyond capacity, force-merge to the nearest cluster.
                var nearest = NearestCluster(embedding);
                if (nearest is int nid)
                {
                    Learn(embedding, nid, now);
                    return nid;
                }
                return null;
            }
        }
        return null;
    }

    /// <summary>Clusters stable enough for live labels / library persistence.</summary>
    public IReadOnlyList<Cluster> StableClusters =>
        _clusters.Where(c => c.LearnCount >= MinSamplesForLiveLabel).ToList();

    public bool IsLiveLabelable(int clusterId) =>
        (_clusters.FirstOrDefault(c => c.Id == clusterId)?.LearnCount ?? 0) >= MinSamplesForLiveLabel;

    public float[]? CentroidOf(int clusterId) =>
        _clusters.FirstOrDefault(c => c.Id == clusterId)?.Centroid;

    /// <summary>Best library match above threshold (lookup only, never writes).</summary>
    public static long? BestLibraryMatch(float[] embedding,
        IReadOnlyList<(long Id, float[] Centroid)> library, float threshold)
    {
        long? bestId = null;
        var best = threshold;
        foreach (var (id, centroid) in library)
        {
            var sim = Cosine(embedding, centroid);
            if (sim > best) { best = sim; bestId = id; }
        }
        return bestId;
    }

    public void Reset() => _clusters.Clear();

    private int? BestMatch(float[] embedding)
    {
        int? bestId = null;
        var best = _matchThreshold;
        foreach (var c in _clusters)
        {
            var sim = Cosine(embedding, c.Centroid);
            foreach (var s in c.Samples)
            {
                var ss = Cosine(embedding, s);
                if (ss > sim) sim = ss;
            }
            if (sim > best) { best = sim; bestId = c.Id; }
        }
        return bestId;
    }

    private int? NearestCluster(float[] embedding)
    {
        Cluster? best = null;
        var bestSim = float.MinValue;
        foreach (var c in _clusters)
        {
            var sim = Cosine(embedding, c.Centroid);
            if (sim > bestSim) { bestSim = sim; best = c; }
        }
        return best?.Id;
    }

    private void Learn(float[] embedding, int id, DateTime at)
    {
        var c = _clusters.FirstOrDefault(x => x.Id == id);
        if (c is null) return;
        var n = (float)c.Samples.Count;
        for (var k = 0; k < c.Centroid.Length; k++)
            c.Centroid[k] = (c.Centroid[k] * n + embedding[k]) / (n + 1);
        c.Samples.Add(embedding);
        if (c.Samples.Count > MaxSamplesPerCluster)
            c.Samples.RemoveAt(0);
        c.LastHeardAt = at;
    }
}
