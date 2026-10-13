using MeetingQ.Infrastructure;
using MeetingQ.Models;

namespace MeetingQ.Services;

/// <summary>
/// Minutes quality scoring — line-by-line port of macOS MinutesQualityAssessor.swift.
/// Same deductions, same thresholds, same bigram overlap.
/// </summary>
public sealed record QualityAssessment(int Score, string Confidence, IReadOnlyList<string> Issues, bool NeedsHumanReview);

public static class MinutesQualityAssessor
{
    public static QualityAssessment Assess(StructuredMinutes minutes, IReadOnlyList<Topic> topics,
        MinutesTemplate template)
    {
        var issues = new List<string>();
        var score = 100;

        var transcriptDecisions = topics.SelectMany(t => t.Decisions).ToList();
        if (transcriptDecisions.Count > 0)
        {
            var recalled = transcriptDecisions.Count(d =>
                minutes.Decisions.Any(m => Overlap(m.Text, d.DecisionText) >= 0.5));
            var recall = (double)recalled / transcriptDecisions.Count;
            if (recall < 0.8)
            {
                score -= 15;
                issues.Add(LocalizationManager.Format("QualMissingDecisionsFmt",
                    transcriptDecisions.Count, minutes.Decisions.Count));
            }
            else if (recall < 0.9)
            {
                score -= 5;
                issues.Add(LocalizationManager.Get("QualDecisionsMostlyComplete"));
            }
        }

        var transcriptActions = topics.SelectMany(t => t.ActionItems).ToList();
        if (transcriptActions.Count > 0)
        {
            var recalled = transcriptActions.Count(a =>
                minutes.ActionItems.Any(m => Overlap(m.Task, a.Task) >= 0.5));
            var recall = (double)recalled / transcriptActions.Count;
            if (recall < 0.7)
            {
                score -= 10;
                issues.Add(LocalizationManager.Format("QualLowActionRecallFmt", (int)(recall * 100)));
            }
        }

        var malformed = minutes.ActionItems.Count(a =>
            string.IsNullOrWhiteSpace(a.Owner) || a.Deadline is null);
        if (minutes.ActionItems.Count > 0 && malformed > minutes.ActionItems.Count / 5)
        {
            score -= 10;
            issues.Add(LocalizationManager.Get("QualMalformedActions"));
        }

        var missing = new List<string>();
        foreach (var section in template.Sections)
        {
            switch (section)
            {
                case MinutesSection.CoreSummary:
                    if (minutes.Summary.Trim().Length < 20) missing.Add(section.Title());
                    break;
                case MinutesSection.Decisions:
                    if (minutes.Decisions.Count == 0 && transcriptDecisions.Count > 0) missing.Add(section.Title());
                    break;
                case MinutesSection.ActionItems:
                    if (minutes.ActionItems.Count == 0 && transcriptActions.Count > 0) missing.Add(section.Title());
                    break;
                case MinutesSection.Risks:
                    if (template.ExpectedDecisionDensity == Density.High && minutes.Risks.Count == 0) missing.Add(section.Title());
                    break;
                case MinutesSection.TopicDetails:
                    if (minutes.TopicDetails.Count == 0 && topics.Count > 1) missing.Add(section.Title());
                    break;
            }
        }
        if (missing.Count > 0)
        {
            score -= 10;
            issues.Add(LocalizationManager.Format("QualTemplateMissFmt", string.Join("、", missing)));
        }

        var summary = minutes.Summary;
        if (summary.Contains("作为AI") || summary.Contains("as an AI") || summary.Contains("```"))
        {
            score -= 6;
            issues.Add(LocalizationManager.Get("QualLanguageIssue"));
        }

        score = Math.Max(0, score);
        var confidence = score >= 90 ? "High" : score >= 70 ? "Medium" : "Low";
        return new QualityAssessment(score, confidence, issues, score < 70);
    }

    private static double Overlap(string a, string b)
    {
        var ta = Bigrams(a);
        var tb = Bigrams(b);
        if (ta.Count == 0 || tb.Count == 0) return 0;
        var inter = ta.Intersect(tb).Count();
        return (double)inter / Math.Min(ta.Count, tb.Count);
    }

    internal static HashSet<string> Bigrams(string s)
    {
        var chars = s.ToLowerInvariant().Where(c => !char.IsWhiteSpace(c) && !char.IsPunctuation(c)).ToArray();
        if (chars.Length < 2)
            return chars.Length == 0 ? new HashSet<string>() : new HashSet<string> { new string(chars) };
        var outSet = new HashSet<string>();
        for (var i = 0; i < chars.Length - 1; i++)
            outSet.Add(new string(chars, i, 2));
        return outSet;
    }
}
