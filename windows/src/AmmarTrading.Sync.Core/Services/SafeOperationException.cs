namespace AmmarTrading.Sync.Core.Services;

public class SafeOperationException : Exception
{
    public SafeOperationException(string code, string message)
        : base(message)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(code);
        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        Code = code;
    }

    public string Code { get; }
}
