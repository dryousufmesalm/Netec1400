namespace AmmarTrading.Sync.App.Hosting;

internal readonly record struct WindowCloseDecision(bool CancelClose, bool StartDrain);

internal sealed class WindowCloseState
{
    private bool _closeApproved;
    private bool _drainStarted;

    public WindowCloseDecision RequestClose(bool canDrainBridge)
    {
        if (_closeApproved)
        {
            return new WindowCloseDecision(CancelClose: false, StartDrain: false);
        }

        if (_drainStarted)
        {
            return new WindowCloseDecision(CancelClose: true, StartDrain: false);
        }

        if (!canDrainBridge)
        {
            return new WindowCloseDecision(CancelClose: false, StartDrain: false);
        }

        _drainStarted = true;
        return new WindowCloseDecision(CancelClose: true, StartDrain: true);
    }

    public void ApproveClose() => _closeApproved = true;
}
