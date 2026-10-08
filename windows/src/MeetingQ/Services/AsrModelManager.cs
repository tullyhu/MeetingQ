using MeetingQ.Infrastructure;
using System.IO;
using System.Net.Http;

namespace MeetingQ.Services;

/// <summary>
/// Resolves local sherpa-onnx model files. Lookup order per file:
///   1. bundled with the app (models/ next to the exe — shipped in the installer)
///   2. %LocalAppData%\MeetingQ\models (previously downloaded)
///   3. downloaded on demand (HuggingFace with hf-mirror fallback, GitHub releases)
/// </summary>
public static class AsrModelManager
{
    public static string LocalRoot { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                     "MeetingQ", "models");

    public static string BundledRoot { get; } =
        Path.Combine(AppContext.BaseDirectory, "models");

    // Streaming Paraformer (bilingual zh-en, int8) — outputs Chinese punctuation natively.
    public static string EncoderPath => Resolve("paraformer/encoder.int8.onnx");
    public static string DecoderPath => Resolve("paraformer/decoder.int8.onnx");
    public static string TokensPath  => Resolve("paraformer/tokens.txt");

    // 3D-Speaker ERes2Net (trained on Chinese speech) for speaker embeddings.
    public static string SpeakerModelPath => Resolve("speaker/eres2net_zh.onnx");

    // pyannote segmentation 3.0 (int8) — used only by the offline post-meeting pass.
    public static string SegmentationModelPath => Resolve("segmentation/pyannote-segmentation-3-0.int8.onnx");

    private const string HfBase =
        "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/";
    private const string HfMirrorBase =
        "https://hf-mirror.com/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/";
    private const string SpeakerModelUrl =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/" +
        "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx";
    private const string SegmentationModelUrl =
        "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.int8.onnx";
    private const string SegmentationModelMirrorUrl =
        "https://hf-mirror.com/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.int8.onnx";

    private sealed record ModelFile(string RelativePath, string[] Urls, long MinSizeBytes)
    {
        public string LocalPath   => Path.Combine(LocalRoot,   RelativePath);
        public string BundledPath => Path.Combine(BundledRoot, RelativePath);
    }

    private static readonly ModelFile[] Files =
    {
        new("paraformer/encoder.int8.onnx", [HfBase + "encoder.int8.onnx", HfMirrorBase + "encoder.int8.onnx"], 10_000_000),
        new("paraformer/decoder.int8.onnx", [HfBase + "decoder.int8.onnx", HfMirrorBase + "decoder.int8.onnx"], 10_000_000),
        new("paraformer/tokens.txt",        [HfBase + "tokens.txt",        HfMirrorBase + "tokens.txt"],        10_000),
        new("speaker/eres2net_zh.onnx",     [SpeakerModelUrl], 1_000_000),
        new("segmentation/pyannote-segmentation-3-0.int8.onnx",
            [SegmentationModelUrl, SegmentationModelMirrorUrl], 1_000_000),
    };

    private static readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(30) };
    private static readonly SemaphoreSlim _downloadGate = new(1, 1);

    public static bool AllPresent => Files.All(f => ResolvePath(f) is not null);

    /// <summary>
    /// Ensures every model file is available, downloading only those that are neither
    /// bundled nor previously downloaded.
    /// </summary>
    public static async Task EnsureModelsAsync(IProgress<string>? progress = null,
        CancellationToken cancellationToken = default)
    {
        await _downloadGate.WaitAsync(cancellationToken);
        try
        {
            foreach (var file in Files)
            {
                if (ResolvePath(file) is not null)
                    continue;

                Directory.CreateDirectory(Path.GetDirectoryName(file.LocalPath)!);
                await DownloadAsync(file, progress, cancellationToken);
            }
        }
        finally
        {
            _downloadGate.Release();
        }
    }

    /// <summary>Returns the path to an available model file (local download preferred,
    /// then bundled). Falls back to the local path (used as download target).</summary>
    private static string Resolve(string relativePath)
    {
        var file = Array.Find(Files, f => f.RelativePath == relativePath)
            ?? throw new ArgumentException($"Unknown model file: {relativePath}");
        return ResolvePath(file) ?? file.LocalPath;
    }

    private static string? ResolvePath(ModelFile file)
    {
        if (IsValid(file, file.LocalPath))   return file.LocalPath;
        if (IsValid(file, file.BundledPath)) return file.BundledPath;
        return null;
    }

    private static bool IsValid(ModelFile file, string path) =>
        File.Exists(path) && new FileInfo(path).Length >= file.MinSizeBytes;

    private static async Task DownloadAsync(ModelFile file, IProgress<string>? progress,
        CancellationToken ct)
    {
        var fileName = Path.GetFileName(file.LocalPath);
        Exception? lastError = null;

        foreach (var url in file.Urls)
        {
            var tmp = file.LocalPath + ".tmp";
            try
            {
                progress?.Report($"正在下载模型 {fileName} ...");
                AppLog.Info("AsrModelManager", $"Downloading {url}");

                using (var resp = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct))
                {
                    resp.EnsureSuccessStatusCode();
                    await using var src = await resp.Content.ReadAsStreamAsync(ct);
                    await using var dst = File.Create(tmp);
                    await src.CopyToAsync(dst, ct);
                }

                if (new FileInfo(tmp).Length < file.MinSizeBytes)
                    throw new InvalidDataException($"文件过小（{new FileInfo(tmp).Length} bytes），可能已损坏");

                File.Move(tmp, file.LocalPath, overwrite: true);
                AppLog.Info("AsrModelManager", $"Downloaded {fileName}");
                return;
            }
            catch (OperationCanceledException)
            {
                TryDelete(tmp);
                throw;
            }
            catch (Exception ex)
            {
                lastError = ex;
                TryDelete(tmp);
                AppLog.Warn("AsrModelManager", $"Download failed ({url}): {ex.Message}");
            }
        }

        throw new InvalidOperationException(
            $"模型 {fileName} 下载失败，请检查网络后重试。", lastError);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }
}
