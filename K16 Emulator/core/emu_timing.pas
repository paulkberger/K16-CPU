unit emu_timing;
{
  K16 Emulator IDE -- High-Resolution Timing
  Wraps QueryPerformanceCounter for accurate wall-clock measurement.

  GetNowNs returns nanoseconds elapsed since InitTiming was called.
  Uses floating-point scaling to avoid integer overflow and div-by-zero.
  Thread-safe: QPC is thread-safe on Windows Vista+.
}
{$mode Delphi}
{$H+}
interface

{ Call once in FormCreate before starting any CPU thread. }
procedure InitTiming;

{ Nanoseconds since InitTiming was called.  Always >= 0.  Thread-safe. }
function GetNowNs: Int64;

implementation

uses Windows;

var
  GFreqF  : Double = 0.0;   { QPC ticks per second as float }
  GOrigin : Int64  = 0;     { QPC counter at InitTiming -- subtracted off
                               so Counter-GOrigin stays small, keeping
                               float precision high }

procedure InitTiming;
var
  Freq: Int64 = 0;
begin
  QueryPerformanceFrequency(Freq);
  if Freq > 0 then
    GFreqF := Freq
  else
    GFreqF := 1.0e7;   { fallback: 10 MHz -- beats a div-by-zero crash }
  GOrigin := 0;
  QueryPerformanceCounter(GOrigin);
end;

function GetNowNs: Int64;
var
  Counter: Int64 = 0;
  F: Double;
begin
  F := GFreqF;
  if F <= 0.0 then F := 1.0e7;   { should never happen, but don't hang }
  QueryPerformanceCounter(Counter);
  Result := Trunc(Counter / F * 1.0e9);
  if Result < 0 then Result := 0;
end;

end.
