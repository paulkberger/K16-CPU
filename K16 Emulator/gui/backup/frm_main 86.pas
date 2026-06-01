unit frm_main;
{
  K16 Emulator IDE -- Main Form
  Part of the K16 homebrew CPU project.
}
{$mode Delphi}
{$H+}
interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs,
  StdCtrls, ExtCtrls, ComCtrls, Grids, Menus, Buttons, Clipbrd,
  LCLType, LCLIntf, Math,
  emu_types, emu_mem, emu_cpu, emu_alu, emu_decode,
  emu_opcodes, emu_debug, emu_io_gui, cpu_thread;

type

  { TfrmMain }

  TfrmMain = class(TForm)
    CheckBoxBP: TCheckBox;
    ComboBox1: TComboBox;
    EditMhz: TEdit;
    EditBP: TEdit;
    EditMemAddress: TEdit;
    FBtnRun: TBitBtn;
    FBtnStep: TBitBtn;
    FBtnStop: TBitBtn;
    FBtnReset: TBitBtn;
    FBtnLoad: TBitBtn;
    FToolBarPanel: TPanel;
    FLeftPanel: TPanel;
    FRightPanel: TPanel;
    GroupBox1: TGroupBox;
    GroupBox2: TGroupBox;
    GBoxDisassembly: TGroupBox;
    GBoxMemory: TGroupBox;
    GroupBoxRegisters: TGroupBox;
    LabelD0: TLabel;
    LabelY1: TLabel;
    LabelY2: TLabel;
    LabelY3: TLabel;
    LabelPC: TLabel;
    LabelSR: TLabel;
    Label15: TLabel;
    LabeLCycles: TLabel;
    LabelSpeed: TLabel;
    LabelD1: TLabel;
    LabelD2: TLabel;
    LabelD3: TLabel;
    LabelX0: TLabel;
    LabelX1: TLabel;
    LabelX2: TLabel;
    LabelX3: TLabel;
    LabelY0: TLabel;
    MemoTerminal: TMemo;
    MemoMessages: TMemo;
    OpenDialog: TOpenDialog;
    Splitter1: TSplitter;
    StringGridDisasm: TStringGrid;
    StringGridMemory: TStringGrid;
    TimerRefresh: TTimer;
    pbVideo: TPanel;

    procedure EditMemAddressEditingDone(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure BtnLoadClick(Sender: TObject);
    procedure BtnRunClick(Sender: TObject);
    procedure BtnStepClick(Sender: TObject);
    procedure BtnStopClick(Sender: TObject);
    procedure BtnResetClick(Sender: TObject);
    procedure CheckBoxBPChange(Sender: TObject);
    procedure EdBPChange(Sender: TObject);
    procedure EdMemAddrChange(Sender: TObject);
    procedure PbVideoPaint(Sender: TObject);
    procedure TmrRefresh(Sender: TObject);
    procedure MemoTerminalKeyPress(Sender: TObject; var Key: Char);
    procedure MemoTerminalKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure MemoTerminalEnter(Sender: TObject);
    procedure MemoTerminalExit(Sender: TObject);

  private
    FCPUThread  : TCPUThread;
    FGUIHandler : TGUIIOHandler;
    FBinFile    : string;
    FVideoBmp   : TBitmap;
    FMemBase    : TAddr;

    FTermQueue  : array[0..65535] of Byte;
    FTermHead   : Integer;
    FTermTail   : Integer;

    FMsgQueue   : array[0..65535] of Byte;
    FMsgHead    : Integer;
    FMsgTail    : Integer;

    FPCHistory  : array[0..63] of TAddr;
    FPCHistIdx  : Integer;
    FMemPCRow   : Integer;
    FLastCycles : QWord;
    FLastTime   : TDateTime;
    FRunStartTime  : TDateTime;  { set when Run pressed }
    FRunStartCycles: QWord;
    FRefreshingMem : Boolean;    { reentrance guard for RefreshMem }

    FSmoothPal  : array[0..255] of LongWord;  { precomputed palette for VideoMode 3 }
    procedure BuildSmoothPalette;

    procedure OnCPUPanelUpdate(Sender: TObject);
    procedure OnCPUHalt(Sender: TObject);
    procedure DisasmCopyRowClick(Sender: TObject);
    procedure DisasmCopyAllClick(Sender: TObject);
    procedure MemCopyRowClick(Sender: TObject);
    procedure MemCopyAllClick(Sender: TObject);
    procedure StartCPU;
    procedure StopCPU;
    procedure LoadAndReset(const FileName: string);
    procedure RefreshRegs;
    procedure RefreshDisasm;
    procedure RefreshMem(SyncToPC: Boolean = True);
    procedure DrainTermQueue;
    procedure TermWrite(ch: Byte);

    procedure DrainMsgQueue;
    procedure MsgWrite(ch: Byte);         { thread-safe: enqueues byte }
    procedure MsgAppend(const s: string); { UI thread only: direct append }

    procedure RecordPC;
    procedure SyncMemToPC;
    procedure UpdateSpeedLabel;
    procedure DebugTermWrite(const s: string);
    procedure MemDrawCell(Sender: TObject; aCol, aRow: Integer; aRect: TRect; aState: TGridDrawState);
    procedure DisasmDrawCell(Sender: TObject; aCol, aRow: Integer; aRect: TRect; aState: TGridDrawState);

  public
    procedure SetVideoMode(mode: Word);
    procedure UpdateVideoBmp;
    function  VGAColour(index: Byte): LongWord;
  end;

procedure VideoModeHook({%H-}addr: TAddr; value: TWord);

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

{ Windows multimedia timer resolution }
function  timeBeginPeriod(uPeriod: LongWord): LongWord; stdcall; external 'winmm.dll';
function  timeEndPeriod  (uPeriod: LongWord): LongWord; stdcall; external 'winmm.dll';

procedure VideoModeHook({%H-}addr: TAddr; value: TWord);
begin
  if Assigned(frmMain) then
    frmMain.SetVideoMode(value);
end;

{ ============================================================ }
{ Form create / destroy                                         }
{ ============================================================ }
procedure TfrmMain.FormCreate(Sender: TObject);
var
  Popup : TPopupMenu;
  Item  : TMenuItem;
begin
  FGUIHandler.Init;
  FGUIHandler.TermOutput := TermWrite;
  IO          := @FGUIHandler;
  IOWriteHook := VideoModeHook;
  timeBeginPeriod(1);   { improve Sleep() resolution to ~1ms }

  FillChar(Mem, SizeOf(Mem), 0);
  InitDispatch;
  CPU.Reset;

  FVideoBmp  := TBitmap.Create;
  pbVideo.Caption  := '';
  pbVideo.Color    := clWhite;
  pbVideo.OnPaint  := PbVideoPaint;
  pbVideo.Width    := 1280;
  pbVideo.Height   := 960;
  GroupBox2.Height := 1022;   { pbVideo.Top(16) + 960 + 16 bottom + 30 caption }

  { Precompute palette for VideoMode 3 }
  BuildSmoothPalette;
  FMemBase   := RESET_VEC;
  FBinFile   := '';
  FTermHead  := 0;
  FTermTail  := 0;
  FMsgHead   := 0;
  FMsgTail   := 0;
  FRefreshingMem := False;
  FillChar(FPCHistory, SizeOf(FPCHistory), 0);
  FPCHistIdx := 0;
  FMemPCRow   := -1;
  FLastCycles   := 0;
  FLastTime     := 0;
  FRunStartTime   := 0;
  FRunStartCycles := 0;

  { Disasm grid: arrow col + disasm text col }
  StringGridDisasm.ColCount     := 3;
  StringGridDisasm.FixedCols    := 0;
  StringGridDisasm.FixedRows    := 0;
  StringGridDisasm.ColWidths[0] := 20;   { arrow }
  StringGridDisasm.ColWidths[1] := 90;   { address }
  StringGridDisasm.ColWidths[2] := StringGridDisasm.Width - 115; { instruction }
  StringGridDisasm.Options      := StringGridDisasm.Options - [goEditing] + [goRowSelect];
  StringGridDisasm.Font.Name    := 'Cascadia Mono';
  StringGridDisasm.Font.Height  := -18;
  StringGridDisasm.Font.Quality := fqDraft;
  StringGridDisasm.OnDrawCell   := DisasmDrawCell;

  { Disasm right-click context menu }
  Popup := TPopupMenu.Create(Self);
  Item  := TMenuItem.Create(Popup);
  Item.Caption := 'Copy Row';
  Item.OnClick := DisasmCopyRowClick;
  Popup.Items.Add(Item);
  Item  := TMenuItem.Create(Popup);
  Item.Caption := 'Copy All';
  Item.OnClick := DisasmCopyAllClick;
  Popup.Items.Add(Item);
  StringGridDisasm.PopupMenu := Popup;

  { Memory grid right-click: Copy Row / Copy All }
  Popup := TPopupMenu.Create(Self);
  Item  := TMenuItem.Create(Popup);
  Item.Caption := 'Copy Row';
  Item.OnClick := MemCopyRowClick;
  Popup.Items.Add(Item);
  Item  := TMenuItem.Create(Popup);
  Item.Caption := 'Copy All';
  Item.OnClick := MemCopyAllClick;
  Popup.Items.Add(Item);
  StringGridMemory.PopupMenu := Popup;

  { Memory grid: blank col[0] + addr col[1] + 16 byte cols = 18 cols }
  StringGridMemory.ColCount     := 18;
  StringGridMemory.FixedCols    := 0;
  StringGridMemory.FixedRows    := 0;
  StringGridMemory.ColWidths[0] := 20;   { blank -- matches disasm arrow col }
  StringGridMemory.ColWidths[1] := 90;   { address }
  StringGridMemory.ColWidths[2] := 34; StringGridMemory.ColWidths[3] := 34;
  StringGridMemory.ColWidths[4] := 34; StringGridMemory.ColWidths[5] := 34;
  StringGridMemory.ColWidths[6] := 34; StringGridMemory.ColWidths[7] := 34;
  StringGridMemory.ColWidths[8] := 34; StringGridMemory.ColWidths[9] := 34;
  StringGridMemory.ColWidths[10] := 34; StringGridMemory.ColWidths[11] := 34;
  StringGridMemory.ColWidths[12] := 34; StringGridMemory.ColWidths[13] := 34;
  StringGridMemory.ColWidths[14] := 34; StringGridMemory.ColWidths[15] := 34;
  StringGridMemory.ColWidths[16] := 34; StringGridMemory.ColWidths[17] := 34;
  StringGridMemory.Options      := StringGridMemory.Options - [goEditing];
  StringGridMemory.OnDrawCell   := MemDrawCell;
  StringGridMemory.Font.Name    := 'Cascadia Mono';
  StringGridMemory.Font.Height  := -18;
  StringGridMemory.Font.Quality := fqDraft;

  { Terminal }
  MemoTerminal.Font.Name    := 'Cascadia Mono';
  MemoTerminal.Font.Height  := -18;
  MemoTerminal.Font.Quality := fqDraft;
  MemoTerminal.ScrollBars   := ssVertical;
  MemoTerminal.WordWrap     := False;
  MemoTerminal.ReadOnly     := True;

  { Messages panel }
  MemoMessages.Font.Name    := 'Cascadia Mono';
  MemoMessages.Font.Height  := -16;
  MemoMessages.Font.Quality := fqDraft;
  MemoMessages.ScrollBars   := ssVertical;
  MemoMessages.WordWrap     := False;
  MemoMessages.ReadOnly     := True;

  { Keyboard -- wire MemoTerminal as focus/input sink }
  MemoTerminal.OnKeyPress         := MemoTerminalKeyPress;
  MemoTerminal.OnKeyDown          := MemoTerminalKeyDown;
  MemoTerminal.OnEnter            := MemoTerminalEnter;
  MemoTerminal.OnExit             := MemoTerminalExit;

  TimerRefresh.Interval := 33;
  EditMemAddress.Text := 'FF0000';
  EditBP.Text         := 'FF0000';
  EditMhz.Text        := '10';

  { Explicitly wire breakpoint controls in case LFM binding is missing }
  EditBP.OnChange    := EdBPChange;
  CheckBoxBP.OnChange := CheckBoxBPChange;

  { Prime BreakAddr from the default text }
  EdBPChange(nil);

  RefreshRegs;
  RefreshDisasm;
  RefreshMem;
end;

procedure TfrmMain.EditMemAddressEditingDone(Sender: TObject);
var v: Int64;
begin
  if TryStrToInt64('$' + Trim(EditMemAddress.Text), v) then
  begin
    FMemBase := v and ADDR_MASK;
    RefreshMem(False);   { user-typed address — don't let SyncMemToPC override it }
  end;

end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  timeEndPeriod(1);
  StopCPU;
  FVideoBmp.Free;
end;

{ ============================================================ }
{ CPU control                                                   }
{ ============================================================ }
procedure TfrmMain.StartCPU;
begin
  if FCPUThread = nil then
  begin
    FCPUThread               := TCPUThread.Create;
    FCPUThread.OnPanelUpdate := OnCPUPanelUpdate;
    FCPUThread.OnHalt        := OnCPUHalt;
    FCPUThread.DebugOut      := DebugTermWrite;
    FCPUThread.Start;
  end;
end;

procedure TfrmMain.StopCPU;
begin
  if FCPUThread <> nil then
  begin
    FCPUThread.DoStop;
    FCPUThread.Terminate;
    FCPUThread.DoStep;
    FCPUThread.WaitFor;
    FreeAndNil(FCPUThread);
  end;
end;

procedure TfrmMain.LoadAndReset(const FileName: string);
var
  LoadAddr : TAddr;
begin
  StopCPU;
  FillChar(Mem, SizeOf(Mem), 0);
  CPU.Reset;
  FTermHead  := 0;
  FTermTail  := 0;
  FMsgHead   := 0;
  FMsgTail   := 0;
  FillChar(FPCHistory, SizeOf(FPCHistory), 0);
  FPCHistIdx := 0;
  FMemPCRow   := -1;
  FLastCycles   := 0;
  FLastTime     := 0;
  FRunStartTime   := 0;
  FRunStartCycles := 0;
  MemoTerminal.Lines.Clear;
  VideoMode  := 0;
  FVideoBmp.SetSize(0, 0);
  pbVideo.Invalidate;
  if FileName <> '' then
  begin
    try
      if SameText(ExtractFileExt(FileName), '.hex') then
      begin
        MemLoadHex(FileName, LoadAddr);
        CPU.PC   := LoadAddr;
        MsgAppend(ExtractFileName(FileName) +
          Format('  —  Loaded at $%6.6X'#10, [LoadAddr]));
      end
      else
      begin
        MemLoadBin(FileName, RESET_VEC);
        MsgAppend(ExtractFileName(FileName) + '  —  Ready'#10);
      end;
      FBinFile := FileName;
    except
      on E: Exception do
        ShowMessage('Load error: ' + E.Message);
    end;
  end;
  RefreshRegs;
  RefreshDisasm;
  RefreshMem;
end;

{ ============================================================ }
{ Button / control handlers                                     }
{ ============================================================ }
procedure TfrmMain.BtnLoadClick(Sender: TObject);
begin
  StopCPU;
  OpenDialog.Filter     := 'K16 Files (*.hex;*.bin)|*.hex;*.bin|Intel HEX (*.hex)|*.hex|K16 Binary (*.bin)|*.bin|All files (*.*)|*.*';
  OpenDialog.DefaultExt := 'hex';
  OpenDialog.Title      := 'Load K16 Program';
  if OpenDialog.Execute then
    LoadAndReset(OpenDialog.FileName);
end;

procedure TfrmMain.BtnRunClick(Sender: TObject);
var mhz: Integer;
begin
  if FBinFile = '' then begin ShowMessage('Load a .bin file first.'); Exit; end;
  case ComboBox1.ItemIndex of
    1: begin  { MHz }
         mhz := StrToIntDef(EditMhz.Text, 10);
         if mhz < 1 then mhz := 1;
         RunMode   := rmTimed;
         TargetMHz := mhz;
       end;
    2: begin  { Hz -- EditMhz value treated as Hz, minimum 1 }
         { TargetMHz is integer MHz -- clamp to 1 as minimum }
         { At 1MHz the emulator runs ~1M instructions/sec which is still fast }
         { True sub-MHz is not supported by rmTimed; use Step button instead }
         RunMode   := rmTimed;
         TargetMHz := 1;
       end;
  else  { Fast }
    RunMode := rmFast;
  end;
  FLastTime       := 0;
  FLastCycles     := 0;
  FRunStartTime   := Now;
  FRunStartCycles := CPU.CycleCount;
  LabelSpeed.Caption := '';
  StartCPU;
  FCPUThread.DoRun;
  MsgAppend('Running...'#10);
end;

procedure TfrmMain.BtnStepClick(Sender: TObject);
begin
  if FBinFile = '' then begin ShowMessage('Load a .bin file first.'); Exit; end;
  StartCPU;
  FCPUThread.DoStop;
  FCPUThread.DoStep;
  MsgAppend('Stepping'#10);
end;

procedure TfrmMain.BtnStopClick(Sender: TObject);
begin
  if FCPUThread <> nil then
  begin
    FCPUThread.DoStop;
    MsgAppend('Stopped'#10);
    LabelSpeed.Caption  := '';
  end;
end;

procedure TfrmMain.BtnResetClick(Sender: TObject);
begin
  LoadAndReset(FBinFile);
  MsgAppend('Reset'#10);
  LabelSpeed.Caption  := '';
end;

procedure TfrmMain.CheckBoxBPChange(Sender: TObject);
begin
  BreakEnabled := CheckBoxBP.Checked;
end;

procedure TfrmMain.EdBPChange(Sender: TObject);
var v: Int64;
begin
  if TryStrToInt64('$' + Trim(EditBP.Text), v) then
    BreakAddr := v and ADDR_MASK;
end;

procedure TfrmMain.EdMemAddrChange(Sender: TObject);
var v: Int64;
begin
  if TryStrToInt64('$' + Trim(EditMemAddress.Text), v) then
  begin
    FMemBase := v and ADDR_MASK;
    RefreshMem(False);   { user-typed address — don't let SyncMemToPC override it }
  end;
end;

{ ============================================================ }
{ Thread callbacks                                              }
{ ============================================================ }
procedure TfrmMain.OnCPUPanelUpdate(Sender: TObject);
begin
  RecordPC;
  RefreshRegs;
  RefreshDisasm;
  RefreshMem;
  DrainTermQueue;
  if VideoMode > 0 then UpdateVideoBmp;
end;

procedure TfrmMain.OnCPUHalt(Sender: TObject);
var
  haltSec    : Double;
  cyclesDone : Int64;
  speedMhz   : Double;
begin
  { Capture time on UI thread -- Now has ~0.1ms resolution }

  RecordPC;
  DrainTermQueue;
  RefreshRegs;
  RefreshDisasm;
  if VideoMode > 0 then UpdateVideoBmp;

  MsgAppend(Format('Halted #$%2.2X  %d cycles'#10,
    [CPU.HaltCode, CPU.CycleCount]));

  { Calculate speed from run-start to halt }
  haltSec := (Now - FRunStartTime) * 86400.0;
  if (FRunStartTime > 0) and (haltSec > 0) then
  begin
    cyclesDone := Int64(CPU.CycleCount) - Int64(FRunStartCycles);
    speedMhz   := cyclesDone / haltSec / 1000000.0;
    if speedMhz >= 1.0 then
      LabelSpeed.Caption := Format('%.2f MHz', [speedMhz])
    else
      LabelSpeed.Caption := Format('%.2f KHz', [speedMhz * 1000]);
  end
end;

procedure TfrmMain.UpdateSpeedLabel;
var
  nowTime  : TDateTime;
  elapsedSec: Double;
  cycles   : QWord;
  mhz      : Double;
begin
  if FCPUThread = nil then Exit;
  if CPU.Halted then Exit;   { don't overwrite halt speed display }

  nowTime := Now;

  { First call -- just record baseline }
  if FLastTime = 0 then
  begin
    FLastTime   := nowTime;
    FLastCycles := CPU.CycleCount;
    Exit;
  end;

  elapsedSec := (nowTime - FLastTime) * 86400.0;
  if elapsedSec <= 0 then Exit;

  cycles := CPU.CycleCount;
  mhz    := (cycles - FLastCycles) / elapsedSec / 1000000.0;
  case ComboBox1.ItemIndex of
    1: LabelSpeed.Caption := IntToStr(TargetMHz) + ' MHz  (' + Format('%.2f', [mhz]) + ')';
  else
    LabelSpeed.Caption := Format('Fast  %.2f MHz', [mhz]);
  end;

  FLastCycles := cycles;
  FLastTime   := nowTime;
end;

procedure TfrmMain.TmrRefresh(Sender: TObject);
begin
  TimerRefresh.Enabled := False;
  try
    DrainTermQueue;
    DrainMsgQueue;
    UpdateSpeedLabel;
    if (VideoMode > 0) and not CPU.Halted then UpdateVideoBmp;
    if (FCPUThread <> nil) and not CPU.Halted then
    begin
      RefreshRegs;
      RefreshDisasm;
      RefreshMem;
      if FCPUThread.BreakpointHit then
      begin
        FCPUThread.ClearBreakpointHit;
        LabelSpeed.Caption  := '';
        MsgAppend(Format('Breakpoint hit at $%6.6X'#10, [CPU.PC]));
      end;
    end;
  finally
    TimerRefresh.Enabled := True;
  end;
end;

{ ============================================================ }
{ Panel refresh                                                 }
{ ============================================================ }
procedure TfrmMain.RefreshRegs;
begin
  LabelD0.Caption    := Format('D0 $%4.4X', [CPU.D[0]]);
  LabelD1.Caption    := Format('D1 $%4.4X', [CPU.D[1]]);
  LabelD2.Caption    := Format('D2 $%4.4X', [CPU.D[2]]);
  LabelD3.Caption    := Format('D3 $%4.4X', [CPU.D[3]]);
  LabelX0.Caption    := Format('X0 $%4.4X', [CPU.X[0]]);
  LabelX1.Caption    := Format('X1 $%4.4X', [CPU.X[1]]);
  LabelX2.Caption    := Format('X2 $%4.4X', [CPU.X[2]]);
  LabelX3.Caption    := Format('X3 $%4.4X', [CPU.X[3]]);
  LabelY0.Caption    := Format('Y0 $%2.2X',  [CPU.Y[0]]);
  LabelY1.Caption    := Format('Y1 $%2.2X',  [CPU.Y[1]]);
  LabelY2.Caption    := Format('Y2 $%2.2X',  [CPU.Y[2]]);
  LabelY3.Caption    := Format('Y3 $%2.2X',  [CPU.Y[3]]);
  LabelPC.Caption    := Format('PC $%6.6X',  [CPU.PC]);
  LabelSR.Caption    := 'SR ' + FormatFlags;
  LabeLCycles.Caption:= Format('Cycles = %d', [CPU.CycleCount]);
end;

procedure TfrmMain.RecordPC;
var
  LastIdx : Integer;
begin
  LastIdx := (FPCHistIdx - 1) and 63;
  if FPCHistory[LastIdx] = CPU.PC then Exit;   { skip duplicate }
  FPCHistory[FPCHistIdx] := CPU.PC;
  FPCHistIdx := (FPCHistIdx + 1) and 63;
end;

procedure TfrmMain.RefreshDisasm;
{ Strategy: PC is always at row CONTEXT.
  Rows 0..CONTEXT-1 come from the PC history ring (real previously-executed addresses).
  Rows CONTEXT..RowCount-1 are disassembled forward from PC.
  No forward-scan guessing -- PC row is always exactly correct. }
const
  CONTEXT = 3;
var
  rows     : Integer;
  row      : Integer;
  used     : Integer;
  addr     : TAddr;
  disline  : string;
  sppos    : Integer;
  histAddrs: array[0..15] of TAddr;
  validHist : array[0..15] of TAddr;
  validCount : Integer;
  h        : Integer;

  procedure PutRow(r: Integer; a: TAddr; isPC: Boolean);
  begin
    if isPC then StringGridDisasm.Cells[0, r] := '►' else StringGridDisasm.Cells[0, r] := '';
    disline := Disassemble(a, used);
    sppos   := Pos('  ', disline);
    if sppos > 0 then
    begin
      StringGridDisasm.Cells[1, r] := Trim(Copy(disline, 1, sppos));
      StringGridDisasm.Cells[2, r] := Trim(Copy(disline, sppos + 1, MaxInt));
    end else
    begin
      StringGridDisasm.Cells[1, r] := disline;
      StringGridDisasm.Cells[2, r] := '';
    end;
  end;

begin
  rows := StringGridDisasm.RowCount;

  { Collect up to CONTEXT history addresses before PC }
  for h := 0 to CONTEXT - 1 do
    histAddrs[h] := FPCHistory[(FPCHistIdx - CONTEXT + h) and 63];

  { Collect valid history entries (non-zero, not current PC) }
  validCount := 0;
  for h := 0 to CONTEXT - 1 do
    if (histAddrs[h] <> 0) and (histAddrs[h] <> CPU.PC) then
    begin
      validHist[validCount] := histAddrs[h];
      Inc(validCount);
    end;

  { Fill history rows: blanks at top, valid entries packed to bottom }
  for row := 0 to CONTEXT - 1 do
  begin
    h := row - (CONTEXT - validCount);   { offset into validHist }
    if h < 0 then
    begin
      StringGridDisasm.Cells[0, row] := '';
      StringGridDisasm.Cells[1, row] := '';
      StringGridDisasm.Cells[2, row] := '';
    end
    else
      PutRow(row, validHist[h], False);
  end;

  { PC row }
  PutRow(CONTEXT, CPU.PC, True);

  { Fill rows below PC by disassembling forward }
  addr := CPU.PC;
  Disassemble(addr, used);   { consume PC instruction to advance addr }
  Inc(addr, used);
  addr := addr and ADDR_MASK;
  for row := CONTEXT + 1 to rows - 1 do
  begin
    PutRow(row, addr, False);
    Inc(addr, used);
    addr := addr and ADDR_MASK;
  end;
end;

procedure TfrmMain.SyncMemToPC;
var
  pcBase   : TAddr;
  visTop   : TAddr;
  visBot   : TAddr;
  rows     : Integer;
begin
  rows     := StringGridMemory.RowCount;
  pcBase   := CPU.PC and $FFFFF0;           { 16-byte row containing PC }
  visTop   := FMemBase;
  visBot   := (FMemBase + TAddr((rows-1) * 16)) and ADDR_MASK;

  { If PC row is not visible, re-centre the grid on PC }
  if (pcBase < visTop) or (pcBase > visBot) then
  begin
    { Put PC row in the upper quarter of the grid }
    if rows > 4 then
      FMemBase := (pcBase - TAddr((rows div 4) * 16)) and ADDR_MASK
    else
      FMemBase := pcBase;
    EditMemAddress.Text := Format('%6.6X', [FMemBase]);
  end;
end;

procedure TfrmMain.RefreshMem(SyncToPC: Boolean);
var
  row, col : Integer;
  addr     : TAddr;
  pcPage   : TAddr;
begin
  if FRefreshingMem then Exit;
  FRefreshingMem := True;
  try
  if SyncToPC then SyncMemToPC;
  FMemPCRow := -1;
  pcPage    := CPU.PC and $FFFFF0;   { PC aligned to 16-byte row }
  for row := 0 to StringGridMemory.RowCount - 1 do
  begin
    addr := (FMemBase + TAddr(row * 16)) and ADDR_MASK;
    { Mark the row containing current PC }
    if (addr and $FFFFF0) = pcPage then
    begin
      StringGridMemory.Cells[0, row] := '►';
      FMemPCRow := row;
    end else
      StringGridMemory.Cells[0, row] := '';
    StringGridMemory.Cells[1, row] := Format('$%6.6X', [addr]);
    for col := 2 to 17 do
      StringGridMemory.Cells[col, row] :=
        Format('%2.2X', [Mem[(addr + TAddr(col-2)) and ADDR_MASK]]);
  end;
  finally
    FRefreshingMem := False;
  end;
end;

procedure TfrmMain.DrainTermQueue;
var
  ch      : Byte;
  buf     : string;
  i       : Integer;
begin
  if FTermHead = FTermTail then Exit;

  { Collect all pending bytes into a buffer first }
  buf := '';
  while FTermHead <> FTermTail do
  begin
    ch        := FTermQueue[FTermHead];
    FTermHead := (FTermHead + 1) and $FFFF;
    if ch = 13 then Continue;   { skip CR }
    buf := buf + Chr(ch);
  end;

  if buf = '' then Exit;

  { Batch into MemoTerminal -- suspend repaints while updating }
  MemoTerminal.Lines.BeginUpdate;
  try
    if MemoTerminal.Lines.Count = 0 then MemoTerminal.Lines.Add('');
    for i := 1 to Length(buf) do
    begin
      if buf[i] = #10 then
        MemoTerminal.Lines.Add('')
      else
        MemoTerminal.Lines[MemoTerminal.Lines.Count-1] :=
          MemoTerminal.Lines[MemoTerminal.Lines.Count-1] + buf[i];
    end;
  finally
    MemoTerminal.Lines.EndUpdate;
  end;

  { Scroll to bottom }
  MemoTerminal.SelStart  := Length(MemoTerminal.Text);
  MemoTerminal.SelLength := 0;
end;

{ ============================================================ }
{ Video                                                         }
{ ============================================================ }
procedure TfrmMain.SetVideoMode(mode: Word);
begin
end;

procedure TfrmMain.BuildSmoothPalette;
{ Linear greyscale for VideoMode 3 (starfield).
  palette[i] = RGB(i, i, i)
    Index   0 = black  (background / cleared pixels)
    Index  64 = dim    (speed-1 slow stars)
    Index 128 = medium (speed-2 stars)
    Index 255 = white  (speed-4 fast/bright stars) }
var
  i: Integer;
begin
  for i := 0 to 255 do
    FSmoothPal[i] := (LongWord(i) shl 16) or (LongWord(i) shl 8) or LongWord(i);
end;

function TfrmMain.VGAColour(index: Byte): LongWord;
const
  EGA: array[0..15] of LongWord = (
    $000000,$0000AA,$00AA00,$00AAAA,
    $AA0000,$AA00AA,$AA5500,$AAAAAA,
    $555555,$5555FF,$55FF55,$55FFFF,
    $FF5555,$FF55FF,$FFFF55,$FFFFFF);
var r, g, bv: Integer;
begin
  { VideoMode 3: linear greyscale — palette[i] = RGB(i,i,i) }
  if VideoMode = 3 then
  begin
    Result := FSmoothPal[index];
    Exit;
  end;

  if index < 16 then Result := EGA[index]
  else if index < 232 then
  begin
    Dec(index, 16);
    r  := (index div 36) * 51;
    g  := ((index div 6) mod 6) * 51;
    bv := (index mod 6) * 51;
    Result := (LongWord(r) shl 16) or (LongWord(g) shl 8) or LongWord(bv);
  end else
  begin
    bv := 8 + (index - 232) * 10;
    Result := (LongWord(bv) shl 16) or (LongWord(bv) shl 8) or LongWord(bv);
  end;
end;

procedure TfrmMain.UpdateVideoBmp;
{ Renders framebuffer into a fresh TBitmap each call (no GDI DDB cache carryover),
  blits directly to the panel via raw Win32 GetDC/BitBlt/ReleaseDC, then stores
  the result in FVideoBmp for PbVideoPaint window-redraw fallback. }
const
  OUT_W = 1280;
  OUT_H = 960;
var
  bmp    : TBitmap;
  sl     : PByte;
  y, x   : Integer;
  sy, sx : Integer;
  c      : LongWord;
  b      : Byte;
  dc     : HDC;
  srcDC  : HDC;
  oldObj : HGDIOBJ;
begin
  if VideoMode = 0 then
  begin
    FVideoBmp.SetSize(0, 0);
    pbVideo.Invalidate;
    Exit;
  end;

  bmp := TBitmap.Create;
  try
    bmp.PixelFormat := pf32bit;
    bmp.SetSize(OUT_W, OUT_H);

    if VideoMode = 1 then
    begin
      { Mono 1024×768 → 1280×960 (5/4 nearest-neighbour scaling) }
      for y := 0 to OUT_H - 1 do
      begin
        sl := bmp.ScanLine[y];
        sy := y * 768 div OUT_H;       { source row 0..767 }
        for x := 0 to OUT_W - 1 do
        begin
          sx := x * 1024 div OUT_W;    { source pixel 0..1023 }
          b  := Mem[FB_BASE + sy * 128 + (sx shr 3)];
          if (b shr (7 - (sx and 7))) and 1 = 1 then
            begin sl^:=$FF; Inc(sl); sl^:=$FF; Inc(sl); sl^:=$FF; Inc(sl); sl^:=$FF; Inc(sl); end
          else
            begin sl^:=$00; Inc(sl); sl^:=$00; Inc(sl); sl^:=$00; Inc(sl); sl^:=$FF; Inc(sl); end;
        end;
      end;
    end
    else
    begin
      { 8bpp 640×480 → 1280×960: exact 2× integer scale, zero artefact }
      for y := 0 to OUT_H - 1 do
      begin
        sy := y * 480 div OUT_H;       { = y div 2 }
        sl := bmp.ScanLine[y];
        for x := 0 to OUT_W - 1 do
        begin
          sx := x * 640 div OUT_W;     { = x div 2 }
          c  := VGAColour(Mem[FB_BASE + sy * 640 + sx]);
          sl^ := c and $FF;           Inc(sl);
          sl^ := (c shr 8)  and $FF;  Inc(sl);
          sl^ := (c shr 16) and $FF;  Inc(sl);
          sl^ := $FF;                 Inc(sl);
        end;
      end;
    end;

    { Blit fresh bitmap directly to panel DC — bypasses all LCL/GDI caching }
    dc     := LCLIntf.GetDC(pbVideo.Handle);
    srcDC  := LCLIntf.CreateCompatibleDC(dc);
    oldObj := LCLIntf.SelectObject(srcDC, bmp.Handle);
    LCLIntf.BitBlt(dc, 0, 0, OUT_W, OUT_H, srcDC, 0, 0, $00CC0020);
    LCLIntf.SelectObject(srcDC, oldObj);
    LCLIntf.DeleteDC(srcDC);
    LCLIntf.ReleaseDC(pbVideo.Handle, dc);

    { Keep a copy for PbVideoPaint window-redraw fallback }
    FVideoBmp.Assign(bmp);
  finally
    bmp.Free;
  end;
end;

procedure TfrmMain.PbVideoPaint(Sender: TObject);
var
  pnl : TPanel;
begin
  pnl := TPanel(Sender);
  if (FVideoBmp.Width > 0) and (FVideoBmp.Height > 0) then
    pnl.Canvas.Draw(0, 0, FVideoBmp)
  else
  begin
    pnl.Canvas.Brush.Color := clWhite;
    pnl.Canvas.FillRect(pnl.ClientRect);
  end;
end;

{ ============================================================ }
{ Keyboard                                                      }
{ ============================================================ }
procedure TfrmMain.MemoTerminalKeyPress(Sender: TObject; var Key: Char);
begin
  if Key >= #32 then
    FGUIHandler.QueueKey(Ord(Key));
  Key := #0;   { suppress default memo behaviour }
end;

procedure TfrmMain.MemoTerminalKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  case Key of
    VK_RETURN : FGUIHandler.QueueKey(13);
    VK_BACK   : FGUIHandler.QueueKey(8);
    VK_ESCAPE : FGUIHandler.QueueKey(27);
    VK_TAB    : begin FGUIHandler.QueueKey(9); Key := 0; end;
    Ord('V')  :
      if ssCtrl in Shift then
      begin
        FGUIHandler.EnqueueString(Clipboard.AsText);
        Key := 0;
      end;
  end;
end;

procedure TfrmMain.MemoTerminalEnter(Sender: TObject);
begin
  MemoTerminal.Color := $00E8FFE8;   { pale green -- keyboard active }
end;

procedure TfrmMain.MemoTerminalExit(Sender: TObject);
begin
  MemoTerminal.Color := clWindow;
end;

{ ============================================================ }
{ Terminal                                                      }
{ ============================================================ }
procedure TfrmMain.TermWrite(ch: Byte);
begin
  FTermQueue[FTermTail] := ch;
  FTermTail := (FTermTail + 1) and $FFFF;
end;

procedure TfrmMain.MsgWrite(ch: Byte);
begin
  FMsgQueue[FMsgTail] := ch;
  FMsgTail := (FMsgTail + 1) and $FFFF;
end;

procedure TfrmMain.MsgAppend(const s: string);
{ UI thread only — appends directly to MemoMessages }
var i: Integer;
begin
  if MemoMessages.Lines.Count = 0 then MemoMessages.Lines.Add('');
  for i := 1 to Length(s) do
  begin
    if s[i] = #10 then
      MemoMessages.Lines.Add('')
    else
      MemoMessages.Lines[MemoMessages.Lines.Count - 1] :=
        MemoMessages.Lines[MemoMessages.Lines.Count - 1] + s[i];
  end;
  MemoMessages.SelStart  := Length(MemoMessages.Text);
  MemoMessages.SelLength := 0;
end;

procedure TfrmMain.DrainMsgQueue;
var
  ch  : Byte;
  buf : string;
  i   : Integer;
begin
  if FMsgHead = FMsgTail then Exit;
  buf := '';
  while FMsgHead <> FMsgTail do
  begin
    ch       := FMsgQueue[FMsgHead];
    FMsgHead := (FMsgHead + 1) and $FFFF;
    if ch = 13 then Continue;
    buf := buf + Chr(ch);
  end;
  if buf <> '' then
    MsgAppend(buf);
end;

procedure TfrmMain.DebugTermWrite(const s: string);
{ CPU thread → enqueue to MsgQueue; drained by timer onto MemoMessages }
var i: Integer;
begin
  for i := 1 to Length(s) do
    MsgWrite(Byte(s[i]));
end;

procedure TfrmMain.MemDrawCell(Sender: TObject; aCol, aRow: Integer;
  aRect: TRect; aState: TGridDrawState);
var
  grid      : TStringGrid;
  txt       : string;
  isPCRow   : Boolean;
  isPCByte  : Boolean;
  byteOffset: Integer;   { which byte within the row is the PC? }
begin
  grid    := Sender as TStringGrid;
  isPCRow := grid.Cells[0, aRow] = '►';

  { Which column corresponds to the exact PC byte? col[2] = byte 0 of row }
  byteOffset := Integer(CPU.PC and $0F);   { 0..15 }
  isPCByte   := isPCRow and (aCol = byteOffset + 2);

  if isPCByte then
  begin
    { Exact PC byte -- stronger highlight }
    grid.Canvas.Brush.Color := clNavy;
    grid.Canvas.Font.Color  := clYellow;
  end else if isPCRow and (aCol = 0) then
  begin
    { Arrow column on PC row }
    grid.Canvas.Brush.Color := clSkyBlue;
    grid.Canvas.Font.Color  := clBlack;
  end else if isPCRow then
  begin
    { Rest of PC row -- subtle tint }
    grid.Canvas.Brush.Color := $00FFE8D5;  { light blue-grey }
    grid.Canvas.Font.Color  := grid.Font.Color;
  end else
  begin
    grid.Canvas.Brush.Color := grid.Color;
    grid.Canvas.Font.Color  := grid.Font.Color;
  end;

  grid.Canvas.FillRect(Rect(aRect.Left+1, aRect.Top+1, aRect.Right, aRect.Bottom));
  txt := grid.Cells[aCol, aRow];
  if txt <> '' then
    grid.Canvas.TextOut(aRect.Left + 3, aRect.Top + 2, txt);
end;

procedure TfrmMain.DisasmDrawCell(Sender: TObject; aCol, aRow: Integer;
  aRect: TRect; aState: TGridDrawState);
var
  grid : TStringGrid;
  txt  : string;
begin
  grid := Sender as TStringGrid;

  if grid.Cells[0, aRow] = '►' then
  begin
    { Current instruction -- highlight }
    grid.Canvas.Brush.Color := clSkyBlue;
    grid.Canvas.Font.Color  := clBlack;
  end else
  begin
    grid.Canvas.Brush.Color := grid.Color;
    grid.Canvas.Font.Color  := grid.Font.Color;
  end;

  grid.Canvas.FillRect(Rect(aRect.Left+1, aRect.Top+1, aRect.Right, aRect.Bottom));
  txt := grid.Cells[aCol, aRow];
  if txt <> '' then
    grid.Canvas.TextOut(aRect.Left + 3, aRect.Top + 2, txt);
end;

procedure TfrmMain.MemCopyRowClick(Sender: TObject);
var
  Row : Integer;
  col : Integer;
  s   : string;
begin
  Row := StringGridMemory.Row;
  s   := Trim(StringGridMemory.Cells[1, Row]);   { address }
  for col := 2 to 17 do
    s := s + ' ' + Trim(StringGridMemory.Cells[col, Row]);
  Clipboard.AsText := Trim(s);
end;

procedure TfrmMain.MemCopyAllClick(Sender: TObject);
var
  Row, col : Integer;
  s, line  : string;
begin
  s := '';
  for Row := 0 to StringGridMemory.RowCount - 1 do
  begin
    line := Trim(StringGridMemory.Cells[1, Row]);
    for col := 2 to 17 do
      line := line + ' ' + Trim(StringGridMemory.Cells[col, Row]);
    s := s + Trim(line) + LineEnding;
  end;
  Clipboard.AsText := s;
end;

procedure TfrmMain.DisasmCopyRowClick(Sender: TObject);
var
  Row : Integer;
  s   : string;
begin
  Row := StringGridDisasm.Row;
  s   := Trim(StringGridDisasm.Cells[1, Row]) + '  ' +
         Trim(StringGridDisasm.Cells[2, Row]);
  Clipboard.AsText := Trim(s);
end;

procedure TfrmMain.DisasmCopyAllClick(Sender: TObject);
var
  Row : Integer;
  s   : string;
begin
  s := '';
  for Row := 0 to StringGridDisasm.RowCount - 1 do
  begin
    s := s + Trim(StringGridDisasm.Cells[1, Row]) + '  ' +
             Trim(StringGridDisasm.Cells[2, Row]) + LineEnding;
  end;
  Clipboard.AsText := s;
end;

end.
