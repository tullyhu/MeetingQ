using MeetingQ.Infrastructure;

namespace MeetingQ.Services;

/// <summary>
/// Template scoring — line-by-line port of macOS TemplateRecommender.swift.
/// Same weights, same thresholds, same fallback.
/// </summary>
public sealed record TemplateRecommendation(
    string TemplateId, string TemplateName, double Score,
    IReadOnlyList<string> MatchReasons, double Confidence);

public static class TemplateRecommender
{
    public static (TemplateRecommendation Best, IReadOnlyList<TemplateRecommendation> Alternatives)
        Recommend(MeetingFeatures features)
    {
        var scored = new List<TemplateRecommendation>();

        foreach (var template in MinutesTemplateLibrary.All)
        {
            var score = 0.0;
            var reasons = new List<string>();

            if (template.SuitableTypes.Contains(features.PredictedType))
            {
                score += 30;
                reasons.Add(LocalizationManager.Format("TplMatchTypeFmt", MeetingTypeName(features.PredictedType)));
                if (features.SlideDecisionCount > 0 || features.ChartCount > 0)
                {
                    score += 5;
                    reasons.Add(LocalizationManager.Get("TplMatchScreenSupport"));
                }
            }

            if (features.SlideDecisionCount > 2 && template.ExpectedDecisionDensity == Density.High)
            {
                score += 10;
                reasons.Add(LocalizationManager.Format("TplSlideDecisionsFmt", features.SlideDecisionCount));
            }
            if (features.SlideActionItemCount > 3 && template.ExpectedActionDensity == Density.High)
            {
                score += 8;
                reasons.Add(LocalizationManager.Format("TplSlideActionsFmt", features.SlideActionItemCount));
            }

            if (features.ChartCount > 2 && template.KeyFeatures.Contains("data_tables"))
            {
                score += 8;
                reasons.Add(LocalizationManager.Format("TplChartsFmt", features.ChartCount));
            }
            if (features.WhiteboardDetected && template.Id == "brainstorming")
            {
                score += 10;
                reasons.Add(LocalizationManager.Get("TplWhiteboard"));
            }

            score += AsrMatchScore(features, template, reasons);

            if (template.DurationInRange(features.DurationMinutes))
            {
                score += 10;
            }
            else if (features.DurationMinutes > 0)
            {
                var dist = features.DurationMinutes < template.PreferredDurationMin
                    ? template.PreferredDurationMin - features.DurationMinutes
                    : features.DurationMinutes - template.PreferredDurationMax;
                score += Math.Max(0, 10 - dist / 6.0);
            }

            scored.Add(new TemplateRecommendation(
                template.Id, template.Name, score, reasons,
                MultimodalConfidence(features, template)));
        }

        scored.Sort((a, b) => b.Score.CompareTo(a.Score));
        var best = scored.Count > 0 ? scored[0] : new TemplateRecommendation(
            MinutesTemplateLibrary.FallbackId,
            MinutesTemplateLibrary.ById(null).Name, 0, Array.Empty<string>(), 0.5);
        return (best, scored.Skip(1).Take(2).ToList());
    }

    private static double AsrMatchScore(MeetingFeatures features, MinutesTemplate template, List<string> reasons)
    {
        var score = 0.0;
        var d = features.DecisionDensity;
        var a = features.ActionDensity;

        switch (template.ExpectedDecisionDensity)
        {
            case Density.High:   if (d > 0.15) score += 8; else if (d > 0.08) score += 4; break;
            case Density.Medium: if (d is > 0.05 and <= 0.2) score += 8; break;
            case Density.Low:    if (d <= 0.08) score += 6; break;
        }
        switch (template.ExpectedActionDensity)
        {
            case Density.High:
                if (a > 0.2) { score += 8; reasons.Add(LocalizationManager.Get("TplHighActionDensity")); }
                else if (a > 0.1) score += 4;
                break;
            case Density.Medium: if (a is > 0.08 and <= 0.25) score += 8; break;
            case Density.Low:    if (a <= 0.12) score += 6; break;
        }

        if (template.Formality == features.Formality) score += 5;

        if (template.Id == "technical_review" && features.TechnicalDensity > 0.05)
        {
            score += 4;
            reasons.Add(LocalizationManager.Format("TplTechDensityFmt", features.TechnicalDensity));
        }
        return Math.Min(score, 25);
    }

    private static double MultimodalConfidence(MeetingFeatures features, MinutesTemplate template)
    {
        var evidence = 0.0;
        if (features.TypeConfidence > 0.7) evidence += 1;
        if (features.SlideCount > 0)
        {
            var typeMatchesSlide =
                (features.PredictedType == "technical_review" && features.SlideDecisionCount + features.SlideActionItemCount > 0)
                || (features.PredictedType == "executive_meeting" && features.ChartCount > 0)
                || (features.PredictedType != "general_meeting" && features.SlideCount >= 3);
            if (typeMatchesSlide) evidence += 1;
        }
        if (features.ChartCount > 0) evidence += 0.5;
        if (features.WhiteboardDetected && template.Id == "brainstorming") evidence += 1;
        if (template.SuitableTypes.Contains(features.PredictedType) && features.SlideCount > 2) evidence += 0.5;
        return Math.Min(evidence / 3.5, 1.0);
    }

    public static string MeetingTypeName(string type) => type switch
    {
        "technical_review"  => LocalizationManager.Get("MtTypeTechnical"),
        "executive_meeting" => LocalizationManager.Get("MtTypeExecutive"),
        "client_meeting"    => LocalizationManager.Get("MtTypeClient"),
        "daily_standup"     => LocalizationManager.Get("MtTypeStandup"),
        "brainstorming"     => LocalizationManager.Get("MtTypeBrainstorm"),
        "project_weekly"    => LocalizationManager.Get("MtTypeWeekly"),
        "board_meeting"     => LocalizationManager.Get("MtTypeBoard"),
        "negotiation"       => LocalizationManager.Get("MtTypeNegotiation"),
        _                   => LocalizationManager.Get("MtTypeGeneral"),
    };
}
