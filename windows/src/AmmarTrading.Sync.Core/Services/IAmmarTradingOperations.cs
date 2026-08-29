using System.Text.Json;

namespace AmmarTrading.Sync.Core.Services;

public interface IAmmarTradingOperations
{
    Task<object> GetSystemStatusAsync(CancellationToken token);
    Task<object> DiscoverMt4AccountsAsync(CancellationToken token);
    Task<object> BrowseForCsvAsync(CancellationToken token);
    Task<object> GetOneDriveRootsAsync(CancellationToken token);
    Task<object> GetConfiguredAccountsAsync(CancellationToken token);
    Task<object> ValidateSelectionAsync(JsonElement payload, CancellationToken token);
    Task<object> ApplySetupAsync(JsonElement payload, CancellationToken token);
    Task<object> RunSyncNowAsync(JsonElement payload, CancellationToken token);
    Task<object> OpenReportingFolderAsync(JsonElement payload, CancellationToken token);
    Task<object> ExportSupportReportAsync(CancellationToken token);
}
