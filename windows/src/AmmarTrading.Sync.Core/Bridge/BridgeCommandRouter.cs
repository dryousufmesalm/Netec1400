using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using AmmarTrading.Sync.Core.Services;

namespace AmmarTrading.Sync.Core.Bridge;

public sealed class BridgeCommandRouter
{
    private const int BridgeVersion = 1;
    private const int MaximumRequestBytes = 64 * 1024;

    private static readonly HashSet<string> RequiredTopLevelProperties =
        new(["version", "id", "command", "payload"], StringComparer.Ordinal);

    private static readonly Regex RequestIdPattern = new(
        "^[A-Za-z0-9-]{1,64}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly Regex UncPathPattern = new(
        "^(?:[^:]+::)?[\\\\/]{2}",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly IAmmarTradingOperations _operations;

    public BridgeCommandRouter(IAmmarTradingOperations operations)
    {
        _operations = operations ?? throw new ArgumentNullException(nameof(operations));
    }

    public async Task<BridgeResponse> RouteAsync(string json, CancellationToken token)
    {
        if (json is null)
        {
            return Failure(string.Empty, "InvalidRequest", "The request is not valid.");
        }

        if (Encoding.UTF8.GetByteCount(json) > MaximumRequestBytes)
        {
            return Failure(string.Empty, "RequestTooLarge", "The request exceeds the 64 KiB limit.");
        }

        BridgeRequest request;
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64,
            });

            if (!HasExactTopLevelShape(document.RootElement))
            {
                return Failure(string.Empty, "InvalidRequest", "The request is not valid.");
            }

            request = JsonSerializer.Deserialize<BridgeRequest>(json, SerializerOptions)
                ?? throw new JsonException("The request body is empty.");
        }
        catch (JsonException)
        {
            return Failure(string.Empty, "InvalidRequest", "The request is not valid.");
        }
        catch (NotSupportedException)
        {
            return Failure(string.Empty, "InvalidRequest", "The request is not valid.");
        }

        var responseId = IsValidRequestId(request.Id) ? request.Id : string.Empty;
        if (request.Version != BridgeVersion)
        {
            return Failure(responseId, "UnsupportedVersion", "The request version is not supported.");
        }

        if (!IsValidRequestId(request.Id))
        {
            return Failure(string.Empty, "InvalidRequestId", "The request ID is not valid.");
        }

        if (request.Payload.ValueKind != JsonValueKind.Object)
        {
            return Failure(request.Id, "InvalidRequest", "The request is not valid.");
        }

        if (!IsAllowlistedCommand(request.Command))
        {
            return Failure(request.Id, "UnknownCommand", "The requested command is not available.");
        }

        if (RequiresSourcePathValidation(request.Command) && ContainsInvalidSourcePath(request.Payload))
        {
            return Failure(request.Id, "InvalidPath", "A selected source must be a local CSV file.");
        }

        try
        {
            var data = await DispatchAsync(request.Command, request.Payload, token).ConfigureAwait(false);
            return new BridgeResponse(
                BridgeVersion,
                request.Id,
                true,
                "Success",
                "The request completed successfully.",
                data);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            return Failure(request.Id, "RequestCancelled", "The request was cancelled.");
        }
        catch
        {
            return Failure(request.Id, "OperationFailed", "The requested operation could not be completed.");
        }
    }

    private static bool HasExactTopLevelShape(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in root.EnumerateObject())
        {
            if (!RequiredTopLevelProperties.Contains(property.Name) || !seen.Add(property.Name))
            {
                return false;
            }
        }

        return seen.SetEquals(RequiredTopLevelProperties);
    }

    private static bool IsValidRequestId(string? id) =>
        id is not null && RequestIdPattern.IsMatch(id);

    private static bool IsAllowlistedCommand(string? command) => command is
        "getSystemStatus" or
        "discoverMt4Accounts" or
        "browseForCsv" or
        "getOneDriveRoots" or
        "getConfiguredAccounts" or
        "validateSelection" or
        "applySetup" or
        "runSyncNow" or
        "openReportingFolder" or
        "exportSupportReport";

    private static bool RequiresSourcePathValidation(string command) => command is
        "validateSelection" or "applySetup";

    private static bool ContainsInvalidSourcePath(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Name.Equals("sourceCsv", StringComparison.OrdinalIgnoreCase))
                {
                    if (property.Value.ValueKind != JsonValueKind.String ||
                        !IsValidLocalCsvPath(property.Value.GetString()))
                    {
                        return true;
                    }
                }

                if (ContainsInvalidSourcePath(property.Value))
                {
                    return true;
                }
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
            {
                if (ContainsInvalidSourcePath(item))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static bool IsValidLocalCsvPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        var trimmedPath = path.Trim();
        return !UncPathPattern.IsMatch(trimmedPath) &&
            trimmedPath.EndsWith(".csv", StringComparison.OrdinalIgnoreCase);
    }

    private Task<object> DispatchAsync(string command, JsonElement payload, CancellationToken token) =>
        command switch
        {
            "getSystemStatus" => _operations.GetSystemStatusAsync(token),
            "discoverMt4Accounts" => _operations.DiscoverMt4AccountsAsync(token),
            "browseForCsv" => _operations.BrowseForCsvAsync(token),
            "getOneDriveRoots" => _operations.GetOneDriveRootsAsync(token),
            "getConfiguredAccounts" => _operations.GetConfiguredAccountsAsync(token),
            "validateSelection" => _operations.ValidateSelectionAsync(payload, token),
            "applySetup" => _operations.ApplySetupAsync(payload, token),
            "runSyncNow" => _operations.RunSyncNowAsync(payload, token),
            "openReportingFolder" => _operations.OpenReportingFolderAsync(payload, token),
            "exportSupportReport" => _operations.ExportSupportReportAsync(token),
            _ => throw new InvalidOperationException("The command was not allowlisted."),
        };

    private static BridgeResponse Failure(string id, string code, string message) =>
        new(BridgeVersion, id, false, code, message, null);
}
