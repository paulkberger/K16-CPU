unit DigitalKeyboard;

interface

uses
  Winapi.Windows, System.SysUtils;

procedure TypeTextIntoDigitalKeyboard(const Text: string);

implementation

var
  FoundMain: HWND;
  FoundKeyboard: HWND;

function EndsWith(const S, Ending: string): Boolean;
begin
  Result := (Length(S) >= Length(Ending)) and
            SameText(Copy(S, Length(S) - Length(Ending) + 1, Length(Ending)), Ending);
end;

function EnumTopLevelProc(hWnd: HWND; lParam: LPARAM): BOOL; stdcall;
var
  buf: array[0..511] of Char;
  title: string;
begin
  GetWindowText(hWnd, buf, Length(buf));
  title := buf;

  if EndsWith(title, '.dig - Digital') then
  begin
    FoundMain := hWnd;
    Result := False; // stop enumeration
  end
  else
    Result := True;
end;

function EnumChildProc(hWnd: HWND; lParam: LPARAM): BOOL; stdcall;
var
  buf: array[0..255] of Char;
begin
  GetWindowText(hWnd, buf, Length(buf));

  if SameText(buf, 'Keyboard') then
  begin
    FoundKeyboard := hWnd;
    Result := False; // stop enumeration
  end
  else
    Result := True;
end;

procedure ForceForeground(h: HWND);
var
  targetThread, myThread: DWORD;
begin
  targetThread := GetWindowThreadProcessId(h, nil);
  myThread := GetCurrentThreadId;

  AttachThreadInput(myThread, targetThread, True);
  SetForegroundWindow(h);
  AttachThreadInput(myThread, targetThread, False);
end;

procedure SendUnicodeChar(ch: WideChar);
var
  Input: TInput;
begin
  ZeroMemory(@Input, SizeOf(Input));
  Input.Itype := INPUT_KEYBOARD;
  Input.ki.dwFlags := KEYEVENTF_UNICODE;
  Input.ki.wScan := Word(ch);
  SendInput(1, Input, SizeOf(Input));

  Input.ki.dwFlags := KEYEVENTF_UNICODE or KEYEVENTF_KEYUP;
  SendInput(1, Input, SizeOf(Input));
end;

procedure TypeTextIntoDigitalKeyboard(const Text: string);
var
  ch: WideChar;
begin
  FoundMain := 0;
  EnumWindows(@EnumTopLevelProc, 0);

  if FoundMain = 0 then
    raise Exception.Create('No Digital window ending in ".dig - Digital" found');

  FoundKeyboard := 0;
  EnumChildWindows(FoundMain, @EnumChildProc, 0);

  if FoundKeyboard = 0 then
    raise Exception.Create('Keyboard subwindow not found');

  ForceForeground(FoundKeyboard);
  Sleep(50);

  for ch in Text do
    SendUnicodeChar(ch);
end;

end.
