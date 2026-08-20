using System.Diagnostics;
using System.Text;

namespace ICam.App.Services;

/// <summary>
/// Structured logging to a rolling file next to the application's data.
///
/// Rules, enforced by review:
/// - never log media bytes, photo contents, or audio samples;
/// - never log key material or pairing digits;
/// - a diagnostics export contains technical logs only.
/// </summary>
public sealed class Log
{
    public static readonly Log App = new("app");
    public static readonly Log Net = new("net");
    public static readonly Log Media = new("media");
    public static readonly Log Camera = new("camera");
    public static readonly Log Security = new("security");

    private static readonly Lock FileLock = new();
    private static readonly string Directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "iCam", "Logs");

    private const long MaxBytes = 4 * 1024 * 1024;

    private readonly string _category;

    private Log(string category) => _category = category;

    public void Info(string message) => Write("INFO", message, null);
    public void Warn(string message) => Write("WARN", message, null);
    public void Error(string message, Exception? error = null) => Write("ERROR", message, error);

    private void Write(string level, string message, Exception? error)
    {
        var line = new StringBuilder()
            .Append(DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"))
            .Append(" [").Append(level).Append("] ")
            .Append(_category).Append(": ")
            .Append(message);

        if (error is not null)
        {
            line.Append(" | ").Append(error.GetType().Name)
                .Append(": ").Append(error.Message);
        }

        Debug.WriteLine(line.ToString());

        lock (FileLock)
        {
            try
            {
                System.IO.Directory.CreateDirectory(Directory);
                var path = Path.Combine(Directory, "icam.log");

                // Rolling, not unbounded. A multi-hour session should not leave
                // a gigabyte of text behind.
                if (File.Exists(path) && new FileInfo(path).Length > MaxBytes)
                {
                    var previous = Path.Combine(Directory, "icam.previous.log");
                    File.Move(path, previous, overwrite: true);
                }
                File.AppendAllText(path, line.AppendLine().ToString(), Encoding.UTF8);
            }
            catch (IOException)
            {
                // Logging must never be the reason something fails.
            }
        }
    }

    /// <summary>The folder a diagnostics export is built from.</summary>
    public static string LogDirectory => Directory;
}
