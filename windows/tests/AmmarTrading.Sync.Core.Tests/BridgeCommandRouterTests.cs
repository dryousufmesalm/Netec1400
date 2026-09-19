using System.Text;
using System.Text.Json;
using AmmarTrading.Sync.Core.Bridge;
using AmmarTrading.Sync.Core.Services;
using Xunit;

namespace AmmarTrading.Sync.Core.Tests;

public sealed class BridgeCommandRouterTests
{
    [Fact]
    public void BridgeResponse_SerializesWithTheJavascriptTransportFieldNames()
    {
        var response = new BridgeResponse(
            1,
            "r1",
            true,
            "Success",
            "The request completed successfully.",
            new { value = 7 });

        var json = JsonSerializer.Serialize(response);

        Assert.Equal(
            """{"version":1,"id":"r1","ok":true,"code":"Success","message":"The request completed successfully.","data":{"value":7}}""",
            json);
    }

    [Fact]
    public async Task RouteAsync_DispatchesValidCommandExactlyOnce()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"getSystemStatus","payload":{}}""",
            default);

        Assert.True(response.Ok);
        Assert.Equal(1, response.Version);
        Assert.Equal("r1", response.Id);
        Assert.Equal("Success", response.Code);
        Assert.Equal("The request completed successfully.", response.Message);
        Assert.Equal("getSystemStatus", Assert.IsType<OperationResult>(response.Data).Operation);
        Assert.Equal(1, operations.CallCounts["getSystemStatus"]);
        Assert.Equal(1, operations.TotalCalls);
    }

    [Theory]
    [InlineData("getSystemStatus")]
    [InlineData("discoverMt4Accounts")]
    [InlineData("browseForCsv")]
    [InlineData("getOneDriveRoots")]
    [InlineData("getConfiguredAccounts")]
    [InlineData("validateSelection")]
    [InlineData("applySetup")]
    [InlineData("runSyncNow")]
    [InlineData("openReportingFolder")]
    [InlineData("exportSupportReport")]
    public async Task RouteAsync_MapsEachAllowlistedCommandToItsOperation(string command)
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);
        var json = JsonSerializer.Serialize(new
        {
            version = 1,
            id = "route-1",
            command,
            payload = new { },
        });

        var response = await router.RouteAsync(json, default);

        Assert.True(response.Ok);
        Assert.Equal(command, Assert.IsType<OperationResult>(response.Data).Operation);
        Assert.Equal(1, operations.CallCounts[command]);
        Assert.Equal(1, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsMessagesOverSixtyFourKibByUtf8ByteCount()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);
        var multibytePadding = new string('\u00E9', 32_769);
        const string prefix = "{\"version\":1,\"id\":\"r1\",\"command\":\"getSystemStatus\",\"payload\":{\"padding\":\"";
        const string suffix = "\"}}";
        var json = prefix + multibytePadding + suffix;

        Assert.True(json.Length < 65_536);
        Assert.True(Encoding.UTF8.GetByteCount(json) > 65_536);

        var response = await router.RouteAsync(json, default);

        Assert.False(response.Ok);
        Assert.Equal("RequestTooLarge", response.Code);
        Assert.Equal(string.Empty, response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_AcceptsMessageAtSixtyFourKibBoundary()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);
        const string prefix = "{\"version\":1,\"id\":\"r1\",\"command\":\"getSystemStatus\",\"payload\":{\"padding\":\"";
        const string suffix = "\"}}";
        var json = prefix + new string('a', 65_536 - prefix.Length - suffix.Length) + suffix;

        var response = await router.RouteAsync(json, default);

        Assert.True(response.Ok);
        Assert.Equal(1, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsUnsupportedVersion()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":2,"id":"r1","command":"getSystemStatus","payload":{}}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("UnsupportedVersion", response.Code);
        Assert.Equal("r1", response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Theory]
    [InlineData("")]
    [InlineData("contains space")]
    [InlineData("has_underscore")]
    [InlineData("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    public async Task RouteAsync_RejectsInvalidRequestIds(string id)
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);
        var json = JsonSerializer.Serialize(new { version = 1, id, command = "getSystemStatus", payload = new { } });

        var response = await router.RouteAsync(json, default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidRequestId", response.Code);
        Assert.Equal(string.Empty, response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsDuplicateTopLevelId()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","id":"r2","command":"getSystemStatus","payload":{}}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidRequest", response.Code);
        Assert.Equal(string.Empty, response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsUnknownCommand()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"deleteEverything","payload":{}}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("UnknownCommand", response.Code);
        Assert.Equal("r1", response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsExtraTopLevelProperty()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"getSystemStatus","payload":{},"admin":true}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidRequest", response.Code);
        Assert.Equal(string.Empty, response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsMissingTopLevelProperty()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"getSystemStatus"}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidRequest", response.Code);
        Assert.Equal(string.Empty, response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsInvalidJson()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync("{not-json", default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidRequest", response.Code);
        Assert.Equal(string.Empty, response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Theory]
    [InlineData("validateSelection")]
    [InlineData("applySetup")]
    public async Task RouteAsync_RejectsUncSourcePathsBeforeDispatch(string command)
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);
        var json = JsonSerializer.Serialize(new
        {
            version = 1,
            id = "r1",
            command,
            payload = new
            {
                accounts = new[] { new { sourceCsv = @"\\server\share\AGOLD___Baskets.csv" } },
            },
        });

        var response = await router.RouteAsync(json, default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidPath", response.Code);
        Assert.Equal("r1", response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Theory]
    [InlineData("validateSelection")]
    [InlineData("applySetup")]
    public async Task RouteAsync_RejectsNonCsvSourcePathsBeforeDispatch(string command)
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);
        var json = JsonSerializer.Serialize(new
        {
            version = 1,
            id = "r1",
            command,
            payload = new
            {
                accounts = new[] { new { sourceCsv = @"C:\MT4\Files\notes.txt" } },
            },
        });

        var response = await router.RouteAsync(json, default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidPath", response.Code);
        Assert.Equal("r1", response.Id);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_RejectsNonObjectPayload()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"getSystemStatus","payload":null}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("InvalidRequest", response.Code);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_DoesNotDispatchWhenCancellationIsAlreadyRequested()
    {
        var operations = new FakeOperations();
        var router = new BridgeCommandRouter(operations);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"applySetup","payload":{}}""",
            cancellation.Token);

        Assert.False(response.Ok);
        Assert.Equal("RequestCancelled", response.Code);
        Assert.Equal("The request was cancelled.", response.Message);
        Assert.DoesNotContain("OperationCanceledException", response.Message, StringComparison.Ordinal);
        Assert.Null(response.Data);
        Assert.Equal(0, operations.TotalCalls);
    }

    [Fact]
    public async Task RouteAsync_ConvertsOperationExceptionsToSafeResponse()
    {
        var operations = new FakeOperations { ExceptionToThrow = new InvalidOperationException("secret=C:\\Users\\someone") };
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"getSystemStatus","payload":{}}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("OperationFailed", response.Code);
        Assert.Equal("The requested operation could not be completed.", response.Message);
        Assert.DoesNotContain("secret", response.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Users", response.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Null(response.Data);
    }

    [Fact]
    public async Task RouteAsync_SurfacesSafeOperationExceptions()
    {
        var operations = new FakeOperations
        {
            ExceptionToThrow = new SafeOperationException(
                "OperationFailed",
                "The selected OneDrive root is not a safe local folder."),
        };
        var router = new BridgeCommandRouter(operations);

        var response = await router.RouteAsync(
            """{"version":1,"id":"r1","command":"validateSelection","payload":{}}""",
            default);

        Assert.False(response.Ok);
        Assert.Equal("OperationFailed", response.Code);
        Assert.Equal("The selected OneDrive root is not a safe local folder.", response.Message);
        Assert.Null(response.Data);
    }

    private sealed record OperationResult(string Operation);

    private sealed class FakeOperations : IAmmarTradingOperations
    {
        private static readonly string[] Commands =
        [
            "getSystemStatus",
            "discoverMt4Accounts",
            "browseForCsv",
            "getOneDriveRoots",
            "getConfiguredAccounts",
            "validateSelection",
            "applySetup",
            "runSyncNow",
            "openReportingFolder",
            "exportSupportReport",
        ];

        public FakeOperations()
        {
            CallCounts = Commands.ToDictionary(command => command, _ => 0, StringComparer.Ordinal);
        }

        public Dictionary<string, int> CallCounts { get; }
        public Exception? ExceptionToThrow { get; init; }
        public int TotalCalls => CallCounts.Values.Sum();

        public Task<object> GetSystemStatusAsync(CancellationToken token) => Invoke("getSystemStatus");
        public Task<object> DiscoverMt4AccountsAsync(CancellationToken token) => Invoke("discoverMt4Accounts");
        public Task<object> BrowseForCsvAsync(CancellationToken token) => Invoke("browseForCsv");
        public Task<object> GetOneDriveRootsAsync(CancellationToken token) => Invoke("getOneDriveRoots");
        public Task<object> GetConfiguredAccountsAsync(CancellationToken token) => Invoke("getConfiguredAccounts");
        public Task<object> ValidateSelectionAsync(JsonElement payload, CancellationToken token) => Invoke("validateSelection");
        public Task<object> ApplySetupAsync(JsonElement payload, CancellationToken token) => Invoke("applySetup");
        public Task<object> RunSyncNowAsync(JsonElement payload, CancellationToken token) => Invoke("runSyncNow");
        public Task<object> OpenReportingFolderAsync(JsonElement payload, CancellationToken token) => Invoke("openReportingFolder");
        public Task<object> ExportSupportReportAsync(CancellationToken token) => Invoke("exportSupportReport");

        private Task<object> Invoke(string command)
        {
            CallCounts[command]++;
            if (ExceptionToThrow is not null)
            {
                return Task.FromException<object>(ExceptionToThrow);
            }

            return Task.FromResult<object>(new OperationResult(command));
        }
    }
}
