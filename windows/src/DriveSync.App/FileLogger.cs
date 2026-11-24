using System.Globalization;
using System.Text;
using DriveSync.Core.Logging;
using Microsoft.Extensions.Logging;

namespace DriveSync.App;

/// <summary>
/// Minimal daily-rolling file logger (%LOCALAPPDATA%\WakeupMonster\DriveApp\logs). Every line passes through
/// <see cref="LogRedactor"/>; file names are only logged at Debug level by the sync code. Keeps 14 days.
/// </summary>
internal sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly string _directory;
    private readonly LogLevel _minimum;
    private readonly object _gate = new();

    public FileLoggerProvider(string directory, LogLevel minimum)
    {
        _directory = directory;
        _minimum = minimum;
        Directory.CreateDirectory(directory);
        foreach (var old in Directory.EnumerateFiles(directory, "driveapp-*.log").Where(f => File.GetLastWriteTimeUtc(f) < DateTime.UtcNow.AddDays(-14)))
        {
            try
            {
                File.Delete(old);
            }
            catch (IOException)
            {
                // ignore
            }
        }
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(this, categoryName);

    public void Dispose()
    {
    }

    private void Write(string category, LogLevel level, string message, Exception? exception)
    {
        var line = new StringBuilder()
            .Append(DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz", CultureInfo.InvariantCulture))
            .Append(" [").Append(level.ToString()[..4].ToUpperInvariant()).Append("] ")
            .Append(category).Append(": ")
            .Append(message);
        if (exception is not null)
        {
            // Type + message only: stack traces are fine, but messages from HTTP stacks can carry URLs.
            line.Append(" | ").Append(exception.GetType().Name).Append(": ").Append(exception.Message);
        }

        var path = Path.Combine(_directory, "driveapp-" + DateTime.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture) + ".log");
        lock (_gate)
        {
            try
            {
                File.AppendAllText(path, LogRedactor.Redact(line.ToString()) + Environment.NewLine);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // logging must never take the app down
            }
        }
    }

    private sealed class FileLogger : ILogger
    {
        private readonly FileLoggerProvider _owner;
        private readonly string _category;

        public FileLogger(FileLoggerProvider owner, string category)
        {
            _owner = owner;
            _category = category;
        }

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => logLevel >= _owner._minimum && logLevel != LogLevel.None;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (IsEnabled(logLevel))
            {
                _owner.Write(_category, logLevel, formatter(state, exception), exception);
            }
        }
    }
}
