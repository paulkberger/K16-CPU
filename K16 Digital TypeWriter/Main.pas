unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  SynEdit, Vcl.StdCtrls;

type
  TForm1 = class(TForm)
    SynEdit1: TSynEdit;
    bSendMemoText: TButton;
    cbShowSpecial: TCheckBox;
    bClearText: TButton;
    procedure bSendMemoTextClick(Sender: TObject);
    procedure cbShowSpecialClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure bClearTextClick(Sender: TObject);
  private
    function FindDigitalWindow: HWND;
    function FindKeyboardWindow: HWND;
    procedure BringToForeground(h: HWND);
    procedure SendTextAsUnicode(const Text: string);
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

{---------------------------------------------}
{   Globals                                   }
{---------------------------------------------}

const
  DIGITAL_SUFFIX = '.dig - Digital';

var
  FoundDigital: HWND;
  FoundKeyboard: HWND;
  DigitalPID: DWORD;

{---------------------------------------------}
{   Find Digital main window                  }
{---------------------------------------------}

function EnumDigitalProc(hWnd: HWND; lParam: LPARAM): BOOL; stdcall;
var
  buf: array[0..511] of Char;
  title: string;
begin
  GetWindowText(hWnd, buf, Length(buf));
  title := buf;

  if (Length(title) >= Length(DIGITAL_SUFFIX)) and
     SameText(Copy(title,
                   Length(title) - Length(DIGITAL_SUFFIX) + 1,
                   Length(DIGITAL_SUFFIX)),
              DIGITAL_SUFFIX) then
  begin
    FoundDigital := hWnd;
    Result := False;
  end
  else
    Result := True;
end;

function TForm1.FindDigitalWindow: HWND;
begin
  FoundDigital := 0;
  EnumWindows(@EnumDigitalProc, 0);
  Result := FoundDigital;
end;

{---------------------------------------------}
{   Find Keyboard window (same process)       }
{---------------------------------------------}

function EnumKeyboardProc(hWnd: HWND; lParam: LPARAM): BOOL; stdcall;
var
  buf: array[0..511] of Char;
  pid: DWORD;
begin
  GetWindowThreadProcessId(hWnd, @pid);
  if pid = DigitalPID then
  begin
    GetWindowText(hWnd, buf, Length(buf));
    if Pos('Keyboard', buf) > 0 then
    begin
      FoundKeyboard := hWnd;
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;

function TForm1.FindKeyboardWindow: HWND;
var
  hDigital: HWND;
begin
  hDigital := FindDigitalWindow;
  if hDigital = 0 then Exit(0);

  GetWindowThreadProcessId(hDigital, @DigitalPID);
  FoundKeyboard := 0;
  EnumWindows(@EnumKeyboardProc, 0);
  Result := FoundKeyboard;
end;

{---------------------------------------------}
{   Form create                               }
{---------------------------------------------}

procedure TForm1.FormCreate(Sender: TObject);
begin
  KeyPreview := True;
  SynEdit1.Options := SynEdit1.Options + [eoShowSpecialChars];
end;

{---------------------------------------------}
{   Ctrl+Enter: Send text and clear           }
{---------------------------------------------}

procedure TForm1.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and (ssCtrl in Shift) then
  begin
    bSendMemoTextClick(nil);
    SynEdit1.Lines.Clear;
    Sleep(100);
    BringToForeground(Self.Handle);
    SynEdit1.SetFocus;
    Key := 0;
  end;
end;

{---------------------------------------------}
{   Bring to foreground                       }
{---------------------------------------------}

procedure TForm1.BringToForeground(h: HWND);
var
  targetThread, myThread: DWORD;
begin
  if h = 0 then Exit;

  targetThread := GetWindowThreadProcessId(h, nil);
  myThread := GetCurrentThreadId;

  AttachThreadInput(myThread, targetThread, True);
  SetForegroundWindow(h);
  AttachThreadInput(myThread, targetThread, False);
end;

{---------------------------------------------}
{   Send Unicode keystrokes                   }
{---------------------------------------------}

procedure TForm1.SendTextAsUnicode(const Text: string);
var
  i: Integer;
  ch: WideChar;
  Input: TInput;
  cleaned: string;
begin
  // Normalize line endings: CRLF -> CR, LF -> CR
  cleaned := Text;
  cleaned := StringReplace(cleaned, #13#10, #13, [rfReplaceAll]);
  cleaned := StringReplace(cleaned, #10, #13, [rfReplaceAll]);

  for i := 1 to cleaned.Length do
  begin
    ch := cleaned[i];

    ZeroMemory(@Input, SizeOf(Input));
    Input.Itype := INPUT_KEYBOARD;
    Input.ki.dwFlags := KEYEVENTF_UNICODE;
    Input.ki.wScan := Word(ch);
    SendInput(1, Input, SizeOf(Input));

    Input.ki.dwFlags := KEYEVENTF_UNICODE or KEYEVENTF_KEYUP;
    SendInput(1, Input, SizeOf(Input));
  end;
end;

{---------------------------------------------}
{   Button: Send text                         }
{---------------------------------------------}

procedure TForm1.bSendMemoTextClick(Sender: TObject);
var
  hKbd: HWND;
begin
  hKbd := FindKeyboardWindow;
  if hKbd = 0 then
  begin
    ShowMessage('Keyboard window not found - is it open in Digital?');
    Exit;
  end;

  BringToForeground(hKbd);
  Sleep(150);

  SendTextAsUnicode(SynEdit1.Text);
end;

{---------------------------------------------}
{   Button: Clear text                        }
{---------------------------------------------}

procedure TForm1.bClearTextClick(Sender: TObject);
begin
  SynEdit1.Lines.Clear;
  SynEdit1.SetFocus;
end;

{---------------------------------------------}
{   Checkbox: Show special chars              }
{---------------------------------------------}

procedure TForm1.cbShowSpecialClick(Sender: TObject);
begin
  if cbShowSpecial.Checked then
    SynEdit1.Options := SynEdit1.Options + [eoShowSpecialChars]
  else
    SynEdit1.Options := SynEdit1.Options - [eoShowSpecialChars];
end;

end.
