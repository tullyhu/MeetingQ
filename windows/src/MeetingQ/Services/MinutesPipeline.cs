using MeetingQ.Data;
using MeetingQ.Models;
using MeetingQ.Services.Interfaces;
using MeetingQ.ViewModels;
using Microsoft.Extensions.Logging;

namespace MeetingQ.Services;

/// <summary>
/// Post-meeting minutes pipeline — mirrors the macOS flow:
/// feature extraction → template recommendation → template-driven prompt →
/// structured parsing → quality assessment → persist; then theme classification.
/// Every step is best-effort: failures fall back to the legacy behaviour and never
/// block session finalization.
/// </summary>
public static class MinutesPipeline
{
    /// <summary>Generates the final structured minutes for a finished session.
    /// Returns true when the template-driven pipeline succeeded end to end.</summary>
    public static async Task<bool> GenerateFinalMinutesAsync(AppDbContext db, MeetingSession session,
        List<Topic> topics, List<Screenshot> screenshots, ILlmService llm, ILogger logger,
        CancellationToken ct = default)
    {
        try
        {
            var features = MeetingFeatureExtractor.Extract(session, topics, screenshots);
            var recommendation = TemplateRecommender.Recommend(features);
            var template = MinutesTemplateLibrary.ById(recommendation.Best.TemplateId);
            logger.LogInformation("[Minutes] Template: {Template} (score {Score:F1}, type {Type})",
                template.Id, recommendation.Best.Score, features.PredictedType);

            var prompt = FloatingWindowViewModel.BuildFinalSummaryPrompt(
                session, topics, screenshots, template, features);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(60));
            var response = await llm.AnalyzeAsync(prompt, timeout.Token);
            var minutes = StructuredMinutes.ParseLlmResponse(response);

            if (!string.IsNullOrWhiteSpace(minutes.Summary))
                session.Summary = minutes.Summary;
            session.MinutesJson  = minutes.Encode();
            session.TemplateId   = template.Id;

            var quality = MinutesQualityAssessor.Assess(minutes, topics, template);
            session.QualityScore = quality.Score;
            logger.LogInformation("[Minutes] Quality {Score} ({Confidence}); issues: {Issues}",
                quality.Score, quality.Confidence, string.Join("; ", quality.Issues));
            if (quality.NeedsHumanReview)
                logger.LogWarning("[Minutes] Score below 70 — human review suggested");

            return true;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[Minutes] Template pipeline failed — falling back to legacy summary");
            return false;
        }
    }

    /// <summary>Classifies the session into a cross-meeting theme (best-effort).</summary>
    public static async Task ClassifyThemeAsync(AppDbContext db, MeetingSession session,
        List<Topic> topics, ILlmService llm, ILogger logger, CancellationToken ct = default)
    {
        try
        {
            var themeId = await ThemeClassifier.ClassifyAsync(db, session, topics, llm, ct);
            if (themeId.HasValue && session.ThemeId != themeId.Value)
            {
                session.ThemeId = themeId.Value;
                logger.LogInformation("[Theme] Session {SessionId} → theme {ThemeId}", session.SessionId, themeId.Value);
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[Theme] Classification failed (non-fatal)");
        }
    }
}
