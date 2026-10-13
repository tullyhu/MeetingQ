using MeetingQ.Infrastructure;
using System.IO;
using System.Text.RegularExpressions;

namespace MeetingQ.Services;

/// <summary>
/// Local OCR via the built-in WinRT engine (Windows.Media.Ocr) — no network, no model
/// downloads, ~100-300ms per screenshot. Used to:
///   1. extract the active speaker's name from meeting-app UI ("张三 正在发言")
///   2. fill OcrText on screenshots when the multimodal (Vision) path is disabled
/// </summary>
public partial class LocalOcrService
{
    // "张三 正在发言" / "李四(发言中)" / "正在发言：王五" — 2~4-char CJK names near
    // speaking indicators used by major meeting apps.
    [GeneratedRegex(@"(?<![一-龥])(?<name>[一-龥]{2,4})\s*[（(]?(?:正在发言|正在讲话|正在说话|发言中|讲话中)[)）]?")]
    private static partial Regex NameBeforeIndicatorRegex();

    [GeneratedRegex(@"(?:正在发言|正在讲话|发言人|主讲人)[:：\s]*(?<name>[一-龥]{2,4})")]
    private static partial Regex NameAfterIndicatorRegex();

    [GeneratedRegex(@"(?<count>\d{1,2})\s*人(?:参会|与会|在会)|参会人数[:：]?\s*(?<count>\d{1,2})|(?<count>\d{1,2})\s*位参会")]
    private static partial Regex ParticipantCountRegex();

    // English equivalents, used when the UI language is English:
    // "John is speaking" / "Jane (speaking)" / "Speaking: John".
    [GeneratedRegex(@"(?<name>[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,2})\s*(?:\(?(?:is\s+)?speaking(?:\s+now)?\)?)", RegexOptions.IgnoreCase)]
    private static partial Regex NameBeforeIndicatorEnRegex();

    [GeneratedRegex(@"(?:speaking|speaker|presenter)\s*[:：]?\s*(?<name>[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,2})", RegexOptions.IgnoreCase)]
    private static partial Regex NameAfterIndicatorEnRegex();

    [GeneratedRegex(@"(?<count>\d{1,2})\s*participants|participants\s*[:：]?\s*(?<count>\d{1,2})", RegexOptions.IgnoreCase)]
    private static partial Regex ParticipantCountEnRegex();

    // Words the indicator regex may capture that are not real names.
    private static readonly HashSet<string> NameBlacklist =
        ["正在", "发言", "讲话", "说话", "大家", "会议", "当前", "全员", "有人", "无人", "主讲",
         "主持人", "现在", "目前", "各位", "所有人", "参会人", "与会者"];

    // English stop words (checked case-insensitively).
    private static readonly HashSet<string> NameBlacklistEn = new(StringComparer.OrdinalIgnoreCase)
        { "speaking", "speaker", "participants", "meeting", "everyone", "current",
          "host", "presenter", "now", "all" };

    public async Task<string?> OcrAsync(string imagePath, CancellationToken ct = default)
    {
        try
        {
            return await Task.Run(async () =>
            {
                var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(imagePath);
                using var stream = await file.OpenAsync(Windows.Storage.FileAccessMode.Read);
                var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);

                // OcrEngine rejects images larger than its max dimension — downscale.
                var maxDim = (uint)OcrMaxDimension();
                Windows.Graphics.Imaging.SoftwareBitmap bitmap;
                if (decoder.PixelWidth > maxDim || decoder.PixelHeight > maxDim)
                {
                    var scale = (double)maxDim / Math.Max(decoder.PixelWidth, decoder.PixelHeight);
                    var transform = new Windows.Graphics.Imaging.BitmapTransform
                    {
                        ScaledWidth  = (uint)(decoder.PixelWidth  * scale),
                        ScaledHeight = (uint)(decoder.PixelHeight * scale)
                    };
                    bitmap = await decoder.GetSoftwareBitmapAsync(
                        Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8,
                        Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                        transform,
                        Windows.Graphics.Imaging.ExifOrientationMode.RespectExifOrientation,
                        Windows.Graphics.Imaging.ColorManagementMode.DoNotColorManage);
                }
                else
                {
                    bitmap = await decoder.GetSoftwareBitmapAsync();
                }

                Windows.Media.Ocr.OcrResult result;
                using (bitmap)
                {
                    var engine = (LocalizationManager.Instance.IsEnglish
                                     ? Windows.Media.Ocr.OcrEngine.TryCreateFromLanguage(
                                           new Windows.Globalization.Language("en"))
                                     : null)
                                 ?? Windows.Media.Ocr.OcrEngine.TryCreateFromLanguage(
                                     new Windows.Globalization.Language("zh-Hans-CN"))
                                 ?? Windows.Media.Ocr.OcrEngine.TryCreateFromUserProfileLanguages();
                    if (engine is null)
                    {
                        AppLog.Warn<LocalOcrService>("[OCR] No OCR engine available");
                        return null;
                    }

                    result = await engine.RecognizeAsync(bitmap);
                }
                return string.IsNullOrWhiteSpace(result.Text) ? null : result.Text;
            }, ct);
        }
        catch (Exception ex)
        {
            AppLog.Warn<LocalOcrService>($"[OCR] Failed for {Path.GetFileName(imagePath)}: {ex.Message}");
            return null;
        }
    }

    /// <summary>Extracts the active speaker's name from a meeting-app screenshot,
    /// or null when no speaking indicator is visible.</summary>
    public async Task<string?> ExtractActiveSpeakerNameAsync(string imagePath, CancellationToken ct = default)
    {
        var text = await OcrAsync(imagePath, ct);
        return ExtractSpeakerName(text);
    }

    public static string? ExtractSpeakerName(string? ocrText)
    {
        if (string.IsNullOrWhiteSpace(ocrText)) return null;

        if (LocalizationManager.Instance.IsEnglish)
        {
            foreach (var regex in new[] { NameBeforeIndicatorEnRegex(), NameAfterIndicatorEnRegex() })
            {
                var m = regex.Match(ocrText);
                if (m.Success)
                {
                    var name = m.Groups["name"].Value;
                    if (!NameBlacklistEn.Contains(name))
                        return name;
                }
            }
            return null;
        }

        foreach (var regex in new[] { NameBeforeIndicatorRegex(), NameAfterIndicatorRegex() })
        {
            var m = regex.Match(ocrText);
            if (m.Success)
            {
                var name = m.Groups["name"].Value;
                if (!NameBlacklist.Contains(name))
                    return name;
            }
        }
        return null;
    }

    public static int? ExtractParticipantCount(string? ocrText)
    {
        if (string.IsNullOrWhiteSpace(ocrText)) return null;
        var regex = LocalizationManager.Instance.IsEnglish
            ? ParticipantCountEnRegex()
            : ParticipantCountRegex();
        var m = regex.Match(ocrText);
        if (!m.Success) return null;
        foreach (var g in m.Groups["count"].Captures.Cast<System.Text.RegularExpressions.Capture>())
        {
            if (int.TryParse(g.Value, out var n) && n is >= 2 and <= 20)
                return n;
        }
        return null;
    }

    private static int OcrMaxDimension()
    {
        // Windows.Media.Ocr historically caps at 3900px per side (varies by engine).
        return 3900;
    }
}
