using System.ComponentModel.DataAnnotations;

namespace MeetingQ.Models;

/// <summary>
/// A persistent voiceprint entry ("voiceprint library"). The embedding is an
/// opaque float vector (L2-normalized, ERes2Net 192-d) — it cannot be turned
/// back into audio. Renaming an entry makes future meetings show the real name
/// live. Ported from macOS DataStore speakers/speaker_embeddings tables.
/// </summary>
public class VoiceprintSpeaker
{
    [Key]
    public long Id { get; set; }

    /// <summary>Empty = unnamed ("未命名"); set via rename or meeting-end naming vote.</summary>
    public string Name { get; set; } = string.Empty;

    /// <summary>Centroid embedding, serialized as little-endian float32 bytes.</summary>
    public byte[]? EmbeddingBlob { get; set; }

    /// <summary>How many learnable samples the centroid was averaged from.</summary>
    public int SampleCount { get; set; }

    public DateTime LastHeardAt { get; set; }

    public bool IsNamed => !string.IsNullOrWhiteSpace(Name);

    public float[]? Centroid
    {
        get
        {
            if (EmbeddingBlob is null || EmbeddingBlob.Length % 4 != 0) return null;
            var v = new float[EmbeddingBlob.Length / 4];
            Buffer.BlockCopy(EmbeddingBlob, 0, v, 0, EmbeddingBlob.Length);
            return v;
        }
        set
        {
            if (value is null) { EmbeddingBlob = null; return; }
            var b = new byte[value.Length * 4];
            Buffer.BlockCopy(value, 0, b, 0, b.Length);
            EmbeddingBlob = b;
        }
    }
}
