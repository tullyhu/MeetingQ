using MeetingQ.Data;
using MeetingQ.Models;
using Microsoft.EntityFrameworkCore;

namespace MeetingQ.Services;

/// <summary>
/// Voiceprint library persistence + CRUD, ported from macOS DataStore speaker
/// methods. Library match threshold 0.75 (merge), cluster match 0.72 — both
/// pending real-meeting calibration (see docs/speaker_diarization_spec.md).
/// </summary>
public sealed class VoiceprintLibraryService
{
    public const float MergeThreshold = 0.75f;
    public const float MatchThreshold = 0.72f;

    private readonly IDbContextFactory<AppDbContext> _factory;

    public VoiceprintLibraryService(IDbContextFactory<AppDbContext> factory)
    {
        _factory = factory;
    }

    public async Task<List<VoiceprintSpeaker>> FetchAllAsync()
    {
        await using var db = await _factory.CreateDbContextAsync();
        return await db.VoiceprintSpeakers.OrderByDescending(s => s.LastHeardAt).ToListAsync();
    }

    /// <summary>Named entries with a centroid, for live / end-of-meeting matching.</summary>
    public async Task<List<(long Id, float[] Centroid)>> FetchNamedCentroidsAsync()
    {
        await using var db = await _factory.CreateDbContextAsync();
        var all = await db.VoiceprintSpeakers.Where(s => s.Name != "").ToListAsync();
        return all.Select(s => (s.Id, s.Centroid))
                  .Where(t => t.Centroid is not null)
                  .Select(t => (t.Id, t.Centroid!))
                  .ToList();
    }

    public async Task<VoiceprintSpeaker> InsertAsync(float[] centroid, int sampleCount, string name = "")
    {
        await using var db = await _factory.CreateDbContextAsync();
        var s = new VoiceprintSpeaker
        {
            Name = name,
            SampleCount = sampleCount,
            LastHeardAt = DateTime.Now,
            Centroid = centroid,
        };
        db.VoiceprintSpeakers.Add(s);
        await db.SaveChangesAsync();
        return s;
    }

    public async Task RenameAsync(long id, string name)
    {
        await using var db = await _factory.CreateDbContextAsync();
        var s = await db.VoiceprintSpeakers.FindAsync(id);
        if (s is null) return;
        s.Name = name.Trim();
        await db.SaveChangesAsync();
    }

    /// <summary>
    /// Merge <paramref name="loserId"/> into <paramref name="winnerId"/>:
    /// sample-count-weighted centroid average, then renormalize.
    /// </summary>
    public async Task MergeAsync(long winnerId, long loserId)
    {
        if (winnerId == loserId) return;
        await using var db = await _factory.CreateDbContextAsync();
        var winner = await db.VoiceprintSpeakers.FindAsync(winnerId);
        var loser = await db.VoiceprintSpeakers.FindAsync(loserId);
        if (winner is null || loser is null) return;

        var wc = winner.Centroid;
        var lc = loser.Centroid;
        if (wc is not null && lc is not null && wc.Length == lc.Length)
        {
            var wn = Math.Max(winner.SampleCount, 1);
            var ln = Math.Max(loser.SampleCount, 1);
            var merged = new float[wc.Length];
            double norm = 0;
            for (var i = 0; i < merged.Length; i++)
            {
                merged[i] = (wc[i] * wn + lc[i] * ln) / (wn + ln);
                norm += merged[i] * merged[i];
            }
            if (norm > 0)
            {
                var inv = (float)(1.0 / Math.Sqrt(norm));
                for (var i = 0; i < merged.Length; i++) merged[i] *= inv;
            }
            winner.Centroid = merged;
            winner.SampleCount = wn + ln;
        }
        if (string.IsNullOrWhiteSpace(winner.Name) && !string.IsNullOrWhiteSpace(loser.Name))
            winner.Name = loser.Name;
        if (loser.LastHeardAt > winner.LastHeardAt)
            winner.LastHeardAt = loser.LastHeardAt;

        db.VoiceprintSpeakers.Remove(loser);
        await db.SaveChangesAsync();
    }

    public async Task DeleteAsync(long id)
    {
        await using var db = await _factory.CreateDbContextAsync();
        var s = await db.VoiceprintSpeakers.FindAsync(id);
        if (s is null) return;
        db.VoiceprintSpeakers.Remove(s);
        await db.SaveChangesAsync();
    }

    public async Task ClearAllAsync()
    {
        await using var db = await _factory.CreateDbContextAsync();
        await db.VoiceprintSpeakers.ExecuteDeleteAsync();
    }

    /// <summary>
    /// End-of-meeting persistence: a stable cluster either merges into a close
    /// existing entry (≥ 0.75) or is inserted as a new unnamed entry. A resolved
    /// OCR/vote name is applied on insert (never overwrites an existing name).
    /// </summary>
    public async Task PersistClusterAsync(float[] centroid, int sampleCount, DateTime lastHeardAt, string? resolvedName = null)
    {
        await using var db = await _factory.CreateDbContextAsync();
        var all = await db.VoiceprintSpeakers.ToListAsync();
        VoiceprintSpeaker? best = null;
        var bestSim = MergeThreshold;
        foreach (var s in all)
        {
            var c = s.Centroid;
            if (c is null) continue;
            var sim = SpeakerClusterer.Cosine(centroid, c);
            if (sim > bestSim) { bestSim = sim; best = s; }
        }

        if (best is not null)
        {
            var bc = best.Centroid!;
            var bn = Math.Max(best.SampleCount, 1);
            var merged = new float[bc.Length];
            double norm = 0;
            for (var i = 0; i < merged.Length; i++)
            {
                merged[i] = (bc[i] * bn + centroid[i] * sampleCount) / (bn + sampleCount);
                norm += merged[i] * merged[i];
            }
            if (norm > 0)
            {
                var inv = (float)(1.0 / Math.Sqrt(norm));
                for (var i = 0; i < merged.Length; i++) merged[i] *= inv;
            }
            best.Centroid = merged;
            best.SampleCount = bn + sampleCount;
            best.LastHeardAt = lastHeardAt;
        }
        else
        {
            db.VoiceprintSpeakers.Add(new VoiceprintSpeaker
            {
                Name = resolvedName ?? "",
                SampleCount = sampleCount,
                LastHeardAt = lastHeardAt,
                Centroid = centroid,
            });
        }
        await db.SaveChangesAsync();
    }
}
