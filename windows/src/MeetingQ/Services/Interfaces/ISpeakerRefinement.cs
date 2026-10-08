namespace MeetingQ.Services.Interfaces;

/// <summary>One diarized speech segment from an offline pass over a recording.</summary>
public sealed record DiarizedSegment(double StartSec, double EndSec, int SpeakerIndex);

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
}
