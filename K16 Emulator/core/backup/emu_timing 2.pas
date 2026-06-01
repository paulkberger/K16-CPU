unit emu_timing;
{
  K16 Emulator IDE -- High-Resolution Timing
  Wraps QueryPerformanceCounter for nanosecond-accurate wall-clock time.
  Used by cpu_thread (throttle pacing) and frm_main (MHz display).

  All public functions are thread-safe (QPC itself is thread-safe on
  multi-core Windows since Vista).
}
{$mode Delphi}
{$H+}
interface

{ Return current wall-clock time in nanoseconds.
  Monotonic, thread-safe, ~100ns resolution on modern hardware. }
function  GetNowNs: Int64;

{ Seconds between two GetNowNs samples. }
function  ElapsedSec(StartNs, EndNs: Int64): Double;

{ Initialise: call once at program start (FormCreate). }
procedure InitTiming;

implementation

uses Windows;

var
  GFreq : Int64 = 0;   { QPC ticks per second; 0 = uninitialised }

procedure InitTiming;
begin
  QueryPerformanceFrequency(GFreq);
  { Frequency is guaranteed non-zero on any hardware that supports QPC,
    which is every Windows machine since XP.  If somehow it is zero the
    division in GetNowNs will raise -- better than silent wrong results. }
end;

function GetNowNs: Int64;
var
  Counter: Int64 = 0;
begin
  QueryPerformanceCounter(Counter);
  { Scale to nanoseconds without overflow:
      Counter * 1_000_000_000 would overflow Int64 for large Counter values.
    Instead: Result = Counter * (1e9 / Freq)
    Using integer arithmetic:  (Counter div Freq) * 1e9
                              + (Counter mod Freq) * 1e9 / Freq  }
  Result := (Counter div GFreq) * 1000000000
           + (Counter mod GFreq) * 1000000000 div GFreq;
end;

function ElapsedSec(StartNs, EndNs: Int64): Double;
begin
  Result := (EndNs - StartNs) / 1.0e9;
end;

end.
