using System.Reflection;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AmmarTrading.Sync.App.Services;

public sealed record SupportReportResult(string Path);

public interface ISupportReportService
{
    SupportReportResult Export(
        JsonElement systemStatus,
        JsonElement discovery,
        JsonElement configuredStatus);
}

public sealed class SupportReportService : ISupportReportService
{
    private static readonly Regex UserProfilePrefix = new(
        "^[A-Za-z]:[\\\\/]Users[\\\\/][^\\\\/]+",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.NonBacktracking);

    private static readonly JsonSerializerOptions ReportSerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private readonly string _supportDirectory;
    private readonly string _applicationVersion;

    public SupportReportService(string runtimeRoot, string? applicationVersion = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(runtimeRoot);
        _supportDirectory = Path.Combine(Path.GetFullPath(runtimeRoot), "support");
        _applicationVersion = string.IsNullOrWhiteSpace(applicationVersion)
            ? Assembly.GetEntryAssembly()?.GetName().Version?.ToString() ?? "Unknown"
            : applicationVersion;
    }

    public SupportReportResult Export(
        JsonElement systemStatus,
        JsonElement discovery,
        JsonElement configuredStatus)
    {
        var report = new SupportReportDocument(
            _applicationVersion,
            ReadString(systemStatus, "WindowsVersion", "windowsVersion") is { Length: > 0 } windowsVersion
                ? windowsVersion
                : Environment.OSVersion.VersionString,
            ReadOneDriveRoots(systemStatus),
            ReadChecks(systemStatus),
            ReadDiscoveries(discovery),
            ReadConfiguredAccounts(configuredStatus));

        SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(_supportDirectory);
        var fileName = $"AmmarTrading-Support-{DateTime.UtcNow:yyyyMMddTHHmmssfffZ}-{Guid.NewGuid():N}.json";
        var reportPath = Path.Combine(_supportDirectory, fileName);
        var temporaryPath = reportPath + ".tmp";
        try
        {
            File.WriteAllText(
                temporaryPath,
                JsonSerializer.Serialize(report, ReportSerializerOptions) + Environment.NewLine,
                new UTF8Encoding(false));
            SecureRuntimeFiles.RestrictFileToCurrentUser(temporaryPath);
            File.Move(temporaryPath, reportPath);
            SecureRuntimeFiles.RestrictFileToCurrentUser(reportPath);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }

        return new SupportReportResult(reportPath);
    }

    private static IReadOnlyList<SupportOneDriveRoot> ReadOneDriveRoots(JsonElement systemStatus)
    {
        var result = new List<SupportOneDriveRoot>();
        foreach (var root in ReadArray(systemStatus, "OneDriveRoots", "oneDriveRoots", "Roots", "roots"))
        {
            result.Add(new SupportOneDriveRoot(
                ReadString(root, "Name", "name"),
                ReadBoolean(root, "Available", "available", "IsActive", "isActive"),
                RedactPath(ReadString(root, "Path", "path"))));
        }

        return result;
    }

    private static IReadOnlyList<SupportCheck> ReadChecks(JsonElement systemStatus)
    {
        var result = new List<SupportCheck>();
        foreach (var check in ReadArray(systemStatus, "Checks", "checks"))
        {
            result.Add(new SupportCheck(
                ReadString(check, "Code", "code", "Name", "name"),
                ReadString(check, "Status", "status"),
                ReadBoolean(check, "Ready", "ready")));
        }

        return result;
    }

    private static IReadOnlyList<SupportDiscovery> ReadDiscoveries(JsonElement discovery)
    {
        var result = new List<SupportDiscovery>();
        foreach (var account in ReadArray(discovery, "Accounts", "accounts"))
        {
            result.Add(new SupportDiscovery(
                ReadString(account, "TerminalId", "terminalId"),
                ReadString(account, "AccountNumber", "accountNumber"),
                ReadString(account, "SchemaVersion", "schemaVersion"),
                ReadString(account, "Eligibility", "eligibility"),
                ReadString(account, "ReasonCode", "reasonCode"),
                ReadString(account, "Freshness", "freshness"),
                RedactPath(ReadString(account, "SourceCsv", "sourceCsv"))));
        }

        return result;
    }

    private static IReadOnlyList<SupportConfiguredAccount> ReadConfiguredAccounts(JsonElement configuredStatus)
    {
        var result = new List<SupportConfiguredAccount>();
        foreach (var account in ReadArray(configuredStatus, "Accounts", "accounts"))
        {
            result.Add(new SupportConfiguredAccount(
                ReadString(account, "AccountNumber", "accountNumber"),
                ReadString(account, "Status", "status"),
                ReadString(account, "StatusCode", "statusCode"),
                ReadString(account, "TaskState", "taskState"),
                ReadString(account, "TaskResultCode", "taskResultCode"),
                RedactPath(ReadString(account, "SourceCsv", "sourceCsv")),
                RedactPath(ReadString(account, "Destination", "destination"))));
        }

        return result;
    }

    private static IEnumerable<JsonElement> ReadArray(JsonElement element, params string[] propertyNames)
    {
        var property = FindProperty(element, propertyNames);
        return property is { ValueKind: JsonValueKind.Array }
            ? property.Value.EnumerateArray().ToArray()
            : Array.Empty<JsonElement>();
    }

    private static string ReadString(JsonElement element, params string[] propertyNames)
    {
        var property = FindProperty(element, propertyNames);
        if (property is null)
        {
            return string.Empty;
        }

        return property.Value.ValueKind switch
        {
            JsonValueKind.String => property.Value.GetString() ?? string.Empty,
            JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => property.Value.GetRawText(),
            _ => string.Empty,
        };
    }

    private static bool ReadBoolean(JsonElement element, params string[] propertyNames)
    {
        var property = FindProperty(element, propertyNames);
        return property is { ValueKind: JsonValueKind.True };
    }

    private static JsonElement? FindProperty(JsonElement element, params string[] propertyNames)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var propertyName in propertyNames)
        {
            if (element.TryGetProperty(propertyName, out var property))
            {
                return property;
            }
        }

        return null;
    }

    private static string RedactPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        var redacted = path;
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(userProfile) &&
            redacted.StartsWith(userProfile, StringComparison.OrdinalIgnoreCase))
        {
            redacted = "%USERPROFILE%" + redacted[userProfile.Length..];
        }

        return UserProfilePrefix.Replace(redacted, "%USERPROFILE%");
    }

    private sealed record SupportReportDocument(
        string ApplicationVersion,
        string WindowsVersion,
        IReadOnlyList<SupportOneDriveRoot> OneDriveRoots,
        IReadOnlyList<SupportCheck> Checks,
        IReadOnlyList<SupportDiscovery> Discoveries,
        IReadOnlyList<SupportConfiguredAccount> ConfiguredAccounts);

    private sealed record SupportOneDriveRoot(string Name, bool Available, string Path);

    private sealed record SupportCheck(string Code, string Status, bool Ready);

    private sealed record SupportDiscovery(
        string TerminalId,
        string AccountNumber,
        string SchemaVersion,
        string Eligibility,
        string ReasonCode,
        string Freshness,
        string SourcePath);

    private sealed record SupportConfiguredAccount(
        string AccountNumber,
        string Status,
        string StatusCode,
        string TaskState,
        string TaskResultCode,
        string SourcePath,
        string DestinationPath);
}
