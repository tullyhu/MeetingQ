namespace MeetingQ.Services;

/// <summary>
/// Incremental speaker clustering over embeddings: each utterance embedding is compared
/// (cosine similarity) against running centroids; above threshold it joins that cluster
/// (and updates its centroid), otherwise a new cluster is created.
/// Cluster indices map to display labels "发言人1", "发言人2", ... in creation order.
/// </summary>
public sealed class OnlineSpeakerCluster
{
    private readonly float _threshold;
    private readonly List<float[]> _centroids = new();
    private readonly List<int> _counts = new();

    /// <param name="threshold">
    /// Cosine similarity above which an embedding is considered the same speaker.
    /// Higher → more, finer-grained speakers; lower → fewer speakers. 0.55-0.65 is a
    /// reasonable range for ERes2Net/CAM++ embeddings.
    /// </param>
    public OnlineSpeakerCluster(float threshold = 0.60f)
    {
        _threshold = threshold;
    }

    public int SpeakerCount => _centroids.Count;

    /// <summary>Assign an embedding to a cluster; returns the 0-based speaker index.</summary>
    public int Assign(float[] embedding)
    {
        Normalize(embedding);

        var best = -1;
        var bestSim = float.MinValue;
        for (var i = 0; i < _centroids.Count; i++)
        {
            var sim = Cosine(_centroids[i], embedding);
            if (sim > bestSim)
            {
                bestSim = sim;
                best = i;
            }
        }

        if (best >= 0 && bestSim >= _threshold)
        {
            // Running-average centroid update (capped so early samples keep influence bounded).
            var centroid = _centroids[best];
            var n = Math.Min(_counts[best], 32);
            for (var k = 0; k < centroid.Length; k++)
                centroid[k] = (centroid[k] * n + embedding[k]) / (n + 1);
            _counts[best]++;
            return best;
        }

        _centroids.Add(embedding);
        _counts.Add(1);
        return _centroids.Count - 1;
    }

    public void Reset()
    {
        _centroids.Clear();
        _counts.Clear();
    }

    private static float Cosine(float[] a, float[] b)
    {
        double dot = 0, na = 0, nb = 0;
        for (var i = 0; i < a.Length; i++)
        {
            dot += a[i] * b[i];
            na += a[i] * a[i];
            nb += b[i] * b[i];
        }
        if (na <= 0 || nb <= 0) return 0;
        return (float)(dot / (Math.Sqrt(na) * Math.Sqrt(nb)));
    }

    public static void NormalizeInPlace(float[] v) => Normalize(v);

    private static void Normalize(float[] v)
    {
        double sum = 0;
        for (var i = 0; i < v.Length; i++) sum += v[i] * v[i];
        if (sum <= 0) return;
        var inv = 1.0 / Math.Sqrt(sum);
        for (var i = 0; i < v.Length; i++) v[i] = (float)(v[i] * inv);
    }
}
