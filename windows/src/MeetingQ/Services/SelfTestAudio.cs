using MeetingQ.Infrastructure;
using Microsoft.Extensions.Logging;
using System.Speech.Synthesis;

namespace MeetingQ.Services;

/// <summary>
/// Plays a spoken test phrase through the system's default audio output so that
/// WASAPI loopback can capture it, exercising the full audio → VAD → ASR pipeline.
/// Phrase and voice follow the UI language (English UI → English voice, else Chinese).
/// </summary>
internal static class SelfTestAudio
{
    internal const string PhraseZh = "会议助手功能自检，一二三，四五六，语音识别测试完成。";
    internal const string PhraseEn = "Meeting Mind self test. One two three. Voice recognition check complete.";

    /// <summary>
    /// Speaks the test phrase synchronously on the default audio output device.
    /// Returns (phrase, isChineseVoice).
    /// </summary>
    internal static Task<(string Phrase, bool IsChineseVoice)> SpeakAsync(
        ILogger logger, CancellationToken ct)
    {
        return Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();

            using var synth = new SpeechSynthesizer();
            synth.SetOutputToDefaultAudioDevice();

            var preferEnglish = LocalizationManager.Instance.IsEnglish;
            var voices = synth.GetInstalledVoices()
                .Where(v => v.Enabled)
                .Select(v => v.VoiceInfo)
                .ToList();

            var preferred = voices.FirstOrDefault(v =>
                preferEnglish
                    ? v.Culture.Name.StartsWith("en", StringComparison.OrdinalIgnoreCase)
                    : v.Culture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase));
            var fallback = voices.FirstOrDefault(v =>
                preferEnglish
                    ? v.Culture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)
                    : v.Culture.Name.StartsWith("en", StringComparison.OrdinalIgnoreCase));

            var selected = preferred ?? fallback;

            bool isZh;
            string phrase;
            if (selected is not null)
            {
                synth.SelectVoice(selected.Name);
                isZh = selected.Culture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
                phrase = isZh ? PhraseZh : PhraseEn;
                logger.LogInformation("[SelfTest] TTS voice: {Voice}", selected.Name);
            }
            else
            {
                phrase = preferEnglish ? PhraseEn : PhraseZh;
                isZh = !preferEnglish;
                logger.LogWarning("[SelfTest] No zh/en TTS voice installed — using system default voice");
            }

            synth.Rate   = -2;   // -10..10; slightly slower improves ASR accuracy
            synth.Volume = 85;

            ct.ThrowIfCancellationRequested();
            synth.Speak(phrase);
            return (phrase, isZh);
        }, ct);
    }
}
