// Contract test for schema-v3 reporting run state.
// It intentionally includes the production EA and exercises only telemetry helpers.
#define OnInit V3TelemetrySource_OnInit
#define OnDeinit V3TelemetrySource_OnDeinit
#define OnTick V3TelemetrySource_OnTick
#include "..\\AmmarTradingGoldEA - ref reset every bar - V3.mq4"
#undef OnInit
#undef OnDeinit
#undef OnTick

int Fail(string message)
{
   Print("V3TelemetryRunStateTest FAILED: ", message);
   return(INIT_FAILED);
}

int OnInit()
{
   TelemetryClearRunContext();
   TelemetryBeginRun((datetime)1760000000, 1500.25);

   if(!TelemetryRunContextIsValid())
      return(Fail("new run context was not initialized"));
   if(g_Telemetry_RunStartTime != (datetime)1760000000)
      return(Fail("RunStartTime was not preserved"));
   if(MathAbs(g_Telemetry_RunStartBalance - 1500.25) > 0.00001)
      return(Fail("RunStartBalance was not preserved"));
   if(g_Telemetry_RunID == "")
      return(Fail("RunID was not created"));

   string expectedRunID = g_Telemetry_RunID;
   g_Telemetry_RunStartTime = 0;
   g_Telemetry_RunStartBalance = 0.0;
   g_Telemetry_RunID = "";
   if(!TelemetryRestoreRunContextFromGlobals())
      return(Fail("run context did not recover from terminal globals"));
   if(g_Telemetry_RunID != expectedRunID)
      return(Fail("recovered RunID differs from original run"));

   TelemetryClearRunContext();
   if(TelemetryRunContextIsValid())
      return(Fail("run context was not cleared"));

   Print("V3TelemetryRunStateTest PASSED");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {}
void OnTick() {}
