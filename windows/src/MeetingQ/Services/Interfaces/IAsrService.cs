namespace MeetingQ.Services.Interfaces;

public class TranscriptEventArgs : EventArgs
{
    public string Text { get; }
    public bool IsFinal { get; }
    public float Confidence { get; }
    /// <summary>
    /// Server-assigned utterance/sentence ID. Increments each time the server starts a new
    /// sentence. When this value changes, the previous sentence is definitively complete.
    /// -1 means the field was absent in the server response.
    /// </summary>
    public int UtteranceId { get; }
    /// <summary>Speaker label from ASR diarization (e.g. "发言人1", "发言人2"), null if disabled.</summary>
    public string? SpeakerLabel { get; }

    public TranscriptEventArgs(string text, bool isFinal, float confidence, int utteranceId = -1,
        string? speakerLabel = null)
    {
        Text = text;
        IsFinal = isFinal;
        Confidence = confidence;
        UtteranceId = utteranceId;
        SpeakerLabel = speakerLabel;
    }
}

public interface IAsrService : IDisposable
{
    event EventHandler<TranscriptEventArgs>? TranscriptReceived;
    /// <summary>Fired when the ASR server returns an error frame (e.g. auth failure).</summary>
    event EventHandler<string>? ErrorReceived;

    Task ConnectAsync(CancellationToken cancellationToken = default);
    Task SendAudioAsync(byte[] audioData, CancellationToken cancellationToken = default);
    /// <summary>
    /// Send end-of-stream, wait for final result, then reconnect for the next utterance.
    /// Called after each VAD segment completes.
    /// </summary>
    Task FinalizeSegmentAsync(CancellationToken cancellationToken = default);
    Task DisconnectAsync(CancellationToken cancellationToken = default);
    bool IsConnected { get; }
}
