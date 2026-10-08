using System.IO;

namespace MeetingQ.Infrastructure;

/// <summary>
/// Manages the user-selectable data storage directory.
/// The directory preference is stored in a fixed pointer file:
///   %LOCALAPPDATA%\MeetingQ\storage_path.txt
/// Actual encrypted data files live in the chosen directory.
/// </summary>
public static class StorageConfig
{
    /// <summary>Fixed location of the pointer file (never changes).</summary>
    private static readonly string PointerDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MeetingQ");

    private static readonly string PointerFile = Path.Combine(PointerDir, "storage_path.txt");

    /// <summary>Default data directory (%APPDATA%\MeetingQ).</summary>
    public static readonly string DefaultDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MeetingQ");

    private static string? _cached;

    /// <summary>Returns the current data storage directory, creating it if needed.</summary>
    public static string GetStorageDir()
    {
        if (_cached is not null) return _cached;

        var dir = DefaultDir;
        try
        {
            if (File.Exists(PointerFile))
            {
                var stored = File.ReadAllText(PointerFile).Trim();
                if (!string.IsNullOrEmpty(stored))
                    dir = stored;
            }
        }
        catch { }

        try
        {
            Directory.CreateDirectory(dir);
        }
        catch
        {
            // Directory not accessible (e.g. removable drive disconnected) — fall back to default
            dir = DefaultDir;
            Directory.CreateDirectory(dir);
        }
        _cached = dir;
        return dir;
    }

    /// <summary>
    /// Persists a new storage directory path.
    /// Does NOT move existing files — call <see cref="MigrateData"/> first if needed.
    /// </summary>
    public static void SetStorageDir(string newPath)
    {
        Directory.CreateDirectory(PointerDir);
        Directory.CreateDirectory(newPath);
        File.WriteAllText(PointerFile, newPath);
        _cached = newPath;
    }

    /// <summary>
    /// Copies all *.dat files from <paramref name="sourcePath"/> to <paramref name="destPath"/>.
    /// Returns the number of files copied.
    /// </summary>
    public static int MigrateData(string sourcePath, string destPath)
    {
        if (!Directory.Exists(sourcePath)) return 0;
        Directory.CreateDirectory(destPath);

        var count = 0;
        foreach (var file in Directory.GetFiles(sourcePath, "*.dat"))
        {
            File.Copy(file, Path.Combine(destPath, Path.GetFileName(file)), overwrite: true);
            count++;
        }
        return count;
    }

    /// <summary>Invalidates the in-process cache (call after SetStorageDir).</summary>
    public static void ResetCache() => _cached = null;
}
