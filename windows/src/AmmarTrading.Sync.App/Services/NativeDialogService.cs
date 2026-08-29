using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace AmmarTrading.Sync.App.Services;

public sealed record NativeProcessInvocation(string FileName, IReadOnlyList<string> ArgumentList);

public sealed record OpenedFolderResult(string Status, string AccountNumber);

public interface IFilePicker
{
    string? PickFile(string filter);
}

public interface INativeProcessLauncher
{
    void Start(NativeProcessInvocation invocation);
}

public interface INativeDialogService
{
    string? BrowseForCsv();

    object OpenConfiguredReportingFolder(JsonElement payload, JsonElement configuredStatus);
}

public sealed class NativeDialogService : INativeDialogService
{
    public const string CsvPickerFilter =
        "MT4 basket CSV (AGOLD___Baskets.csv)|AGOLD___Baskets.csv|CSV files (*.csv)|*.csv";

    private static readonly Regex AccountNumberPattern = new(
        "^[0-9]{4,20}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private readonly IFilePicker _filePicker;
    private readonly INativeProcessLauncher _processLauncher;

    public NativeDialogService()
        : this(new WindowsFilePicker(), new SystemNativeProcessLauncher())
    {
    }

    public NativeDialogService(IFilePicker filePicker, INativeProcessLauncher processLauncher)
    {
        _filePicker = filePicker ?? throw new ArgumentNullException(nameof(filePicker));
        _processLauncher = processLauncher ?? throw new ArgumentNullException(nameof(processLauncher));
    }

    public string? BrowseForCsv()
    {
        var selected = _filePicker.PickFile(CsvPickerFilter);
        if (string.IsNullOrWhiteSpace(selected))
        {
            return null;
        }

        var fullPath = Path.GetFullPath(selected);
        if (!File.Exists(fullPath) ||
            !Path.GetExtension(fullPath).Equals(".csv", StringComparison.OrdinalIgnoreCase) ||
            !IsLocalFileSystemPath(fullPath) ||
            HasReparsePointInExistingPath(fullPath))
        {
            throw new PowerShellOperationException(
                "InvalidPath",
                "A selected source must be a local CSV file.");
        }

        return fullPath;
    }

    public object OpenConfiguredReportingFolder(JsonElement payload, JsonElement configuredStatus)
    {
        if (payload.ValueKind != JsonValueKind.Object || configuredStatus.ValueKind != JsonValueKind.Object)
        {
            throw InvalidConfiguredFolder();
        }

        var requestedAccounts = ReadRequestedAccountNumbers(payload);
        var configuredAccounts = GetProperty(configuredStatus, "Accounts", "accounts");
        if (configuredAccounts is null || configuredAccounts.Value.ValueKind != JsonValueKind.Array)
        {
            throw InvalidConfiguredFolder();
        }

        foreach (var configuredAccount in configuredAccounts.Value.EnumerateArray())
        {
            var accountNumber = GetString(configuredAccount, "AccountNumber", "accountNumber");
            if (!AccountNumberPattern.IsMatch(accountNumber) ||
                (requestedAccounts.Count > 0 && !requestedAccounts.Contains(accountNumber)))
            {
                continue;
            }

            var destination = GetString(configuredAccount, "Destination", "destination");
            var accountDirectory = VerifyConfiguredAccountDirectory(destination, accountNumber);
            _processLauncher.Start(new NativeProcessInvocation(
                "explorer.exe",
                new[] { accountDirectory }));
            return new OpenedFolderResult("Opened", accountNumber);
        }

        throw InvalidConfiguredFolder();
    }

    private static HashSet<string> ReadRequestedAccountNumbers(JsonElement payload)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        var values = GetProperty(payload, "accountNumbers", "AccountNumbers");
        if (values is null)
        {
            return result;
        }

        if (values.Value.ValueKind != JsonValueKind.Array)
        {
            throw InvalidConfiguredFolder();
        }

        foreach (var value in values.Value.EnumerateArray())
        {
            var accountNumber = value.ValueKind == JsonValueKind.String
                ? value.GetString() ?? string.Empty
                : string.Empty;
            if (!AccountNumberPattern.IsMatch(accountNumber) || !result.Add(accountNumber))
            {
                throw InvalidConfiguredFolder();
            }
        }

        return result;
    }

    private static string VerifyConfiguredAccountDirectory(string destination, string accountNumber)
    {
        if (string.IsNullOrWhiteSpace(destination))
        {
            throw InvalidConfiguredFolder();
        }

        var canonicalDestination = Path.GetFullPath(destination);
        var accountDirectory = Path.GetDirectoryName(canonicalDestination);
        var productDirectory = accountDirectory is null ? null : Path.GetDirectoryName(accountDirectory);
        if (!Path.GetFileName(canonicalDestination).Equals("Baskets.csv", StringComparison.OrdinalIgnoreCase) ||
            !IsLocalFileSystemPath(canonicalDestination) ||
            accountDirectory is null ||
            productDirectory is null ||
            !Path.GetFileName(accountDirectory).Equals($"Account_{accountNumber}", StringComparison.Ordinal) ||
            !Path.GetFileName(productDirectory).Equals("AmmarTrading", StringComparison.Ordinal) ||
            !Directory.Exists(accountDirectory) ||
            HasReparsePointInExistingPath(accountDirectory) ||
            !IsLocalFileSystemPath(accountDirectory))
        {
            throw InvalidConfiguredFolder();
        }

        return accountDirectory;
    }

    private static bool IsLocalFileSystemPath(string fullPath)
    {
        if (!Path.IsPathRooted(fullPath) || fullPath.StartsWith("\\\\", StringComparison.Ordinal))
        {
            return false;
        }

        var volumeRoot = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(volumeRoot))
        {
            return false;
        }

        try
        {
            return new DriveInfo(volumeRoot).DriveType != DriveType.Network;
        }
        catch
        {
            return false;
        }
    }

    private static bool HasReparsePointInExistingPath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(root))
        {
            return true;
        }

        var current = root;
        foreach (var part in fullPath[root.Length..].Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if (!File.Exists(current) && !Directory.Exists(current))
            {
                break;
            }

            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                return true;
            }
        }

        return false;
    }

    private static JsonElement? GetProperty(JsonElement element, string firstName, string secondName)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(firstName, out var first))
        {
            return first;
        }

        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(secondName, out var second))
        {
            return second;
        }

        return null;
    }

    private static string GetString(JsonElement element, string firstName, string secondName)
    {
        var property = GetProperty(element, firstName, secondName);
        return property is { ValueKind: JsonValueKind.String }
            ? property.Value.GetString() ?? string.Empty
            : string.Empty;
    }

    private static PowerShellOperationException InvalidConfiguredFolder() =>
        new("InvalidConfiguredFolder", "No verified configured account folder is available.");
}

public sealed class WindowsFilePicker : IFilePicker
{
    public string? PickFile(string filter)
    {
        var dialog = new OpenFileDialog
        {
            AddExtension = true,
            CheckFileExists = true,
            CheckPathExists = true,
            DereferenceLinks = true,
            Filter = filter,
            Multiselect = false,
            Title = "Select an MT4 basket CSV",
            ValidateNames = true,
        };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    }
}

public sealed class SystemNativeProcessLauncher : INativeProcessLauncher
{
    public void Start(NativeProcessInvocation invocation)
    {
        ArgumentNullException.ThrowIfNull(invocation);
        var startInfo = new ProcessStartInfo
        {
            FileName = invocation.FileName,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in invocation.ArgumentList)
        {
            startInfo.ArgumentList.Add(argument);
        }

        Process.Start(startInfo)?.Dispose();
    }
}
