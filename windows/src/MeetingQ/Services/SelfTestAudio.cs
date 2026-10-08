using Microsoft.Extensions.Logging;
using System.Speech.Synthesis;

namespace MeetingQ.Services;

/// <summary>
/// Plays a spoken test phrase through the system's default audio output so that
/// WASAPI loopback can capture it, exercising the full audio → VAD → ASR pipeline.
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

            var zhVoice = synth.GetInstalledVoices()
                .FirstOrDefault(v => v.Enabled &&
                    v.VoiceInfo.Culture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase));

            bool isZh;
            string phrase;
            if (zhVoice is not null)
            {
                synth.SelectVoice(zhVoice.VoiceInfo.Name);
                phrase = PhraseZh;
                isZh   = true;
                logger.LogInformation("[SelfTest] TTS voice: {Voice}", zhVoice.VoiceInfo.Name);
            }
            else
            {
                phrase = PhraseEn;
                isZh   = false;
                logger.LogWarning("[SelfTest] No zh-CN voice installed — using English fallback");
            }

            synth.Rate   = -2;   // -10..10; slightly slower improves ASR accuracy
            synth.Volume = 85;

            ct.ThrowIfCancellationRequested();
            synth.Speak(phrase);
            return (phrase, isZh);
        }, ct);
    }
}
