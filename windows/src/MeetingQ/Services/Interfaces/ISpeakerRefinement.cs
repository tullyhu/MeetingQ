namespace MeetingQ.Services.Interfaces;

/// <summary>One diarized speech segment from an offline pass over a recording.</summary>
public sealed record DiarizedSegment(double StartSec, double EndSec, int SpeakerIndex);

/// <summary>A stable live-meeting voiceprint cluster (≥2 learnable samples).</summary>
public sealed record StableVoiceprintCluster(int ClusterId, float[] Centroid, int LearnCount, DateTime LastHeardAt);

/// <summary>
/// Optional capability of an ASR service: records meeting audio locally and can run an
/// offline speaker-diarization pass over the last recording (higher accuracy than the
/// real-time online clustering). Implemented by SherpaOnnxAsrService.
/// </summary>
public interface ISpeakerRefinement
{
    /// <summary>Path of the most recently completed recording (WAV), null if none.</summary>
    string? LastRecordingPath { get; }

    /// <summary>Wall-clock time when the first audio frame of the recording was written.</summary>
    DateTime? RecordingStartedAt { get; }

    /// <summary>
    /// Runs offline diarization (pyannote segmentation + ERes2Net embedding + clustering)
    /// over <see cref="LastRecordingPath"/>. Returns segments sorted by start time.
    /// The recording is deleted after a successful pass (audio is not kept on disk).
    /// </summary>
    /// <param name="numClustersHint">
    /// Known participant count (e.g. OCR'd from the meeting UI); constrains clustering.
    /// Null = fully automatic.
    /// </param>
    Task<List<DiarizedSegment>> DiarizeLastRecordingAsync(
        int? numClustersHint = null, CancellationToken cancellationToken = default);

    /// <summary>Stable live-meeting voiceprint clusters, for end-of-meeting persistence.</summary>
    IReadOnlyList<StableVoiceprintCluster> GetStableVoiceprintClusters();

    /// <summary>
    /// Persists each stable cluster into the voiceprint library (merge ≥0.75 or insert).
    /// <paramref name="nameResolver"/> maps cluster id → OCR/vote-resolved name, if any.
    /// Single-cluster meetings are skipped by the caller (spec R5: no separation happened).
    /// </summary>
    Task PersistVoiceprintsAsync(Func<int, string?> nameResolver, CancellationToken cancellationToken = default);
}
