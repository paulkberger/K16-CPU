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
  StdCtrls, ExtCtrls, ComCtrls, Grids, Menus, Buttons,
  Math,
  LCLType, LCLIntf,
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
    LabelStatus: TLabel;
    LabelD1: TLabel;
    LabelD2: TLabel;
    LabelD3: TLabel;
    LabelX0: TLabel;
    LabelX1: TLabel;
    LabelX2: TLabel;
    LabelX3: TLabel;
    LabelY0: TLabel;
    MemoTerminal: TMemo;
    OpenDialog: TOpenDialog;
    pbVideo: TPaintBox;
    Splitter1: TSplitter;
    StringGridDisasm: TStringGrid;
    StringGridMemory: TStringGrid;
    TimerRefresh: TTimer;

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

  private
    FCPUThread  : TCPUThread;
    FGUIHandler : TGUIIOHandler;
    FBinFile    : string;
    FVideoBmp   : TBitmap;
    FVideoMode  : Word;
    FMemBase    : TAddr;

    FTermQueue  : array[0..255] of Byte;
    FTermHead   : Integer;
    FTermTail   : Integer;

    procedure OnCPUPanelUpdate(Sender: TObject);
    procedure OnCPUHalt(Sender: TObject);
    procedure StartCPU;
    procedure StopCPU;
    procedure LoadAndReset(const FileName: string);
    procedure RefreshRegs;
    procedure RefreshDisasm;
    procedure RefreshMem;
    procedure DrainTermQueue;
    procedure TermWrite(ch: Byte);

  public
    procedure SetVideoMode(mode: Word);
  end;

procedure VideoModeHook(addr: TAddr; value: TWord);

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

procedure VideoModeHook(addr: TAddr; value: TWord);
begin
  if Assigned(frmMain) then
    frmMain.SetVideoMode(value);
end;

{ ============================================================ }
{ Form create / destroy                                         }
{ ============================================================ }
procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FGUIHandler.Init;
  FGUIHandler.TermOutput := TermWrite;
  IO          := @FGUIHandler;
  IOWriteHook := VideoModeHook;

  FillChar(Mem, SizeOf(Mem), 0);
  InitDispatch;
  CPU.Reset;

  FVideoBmp  := TBitmap.Create;
  FVideoMode := 0;
  FMemBase   := RESET_VEC;
  FBinFile   := '';
  FTermHead  := 0;
  FTermTail  := 0;

  { Disasm grid: arrow col + disasm text col }
  StringGridDisasm.ColCount     := 2;
  StringGridDisasm.FixedCols    := 0;
  StringGridDisasm.FixedRows    := 0;
  StringGridDisasm.ColWidths[0] := 20;
  StringGridDisasm.ColWidths[1] := StringGridDisasm.Width - 24;
  StringGridDisasm.Options      := StringGridDisasm.Options - [goEditing] + [goRowSelect];
  StringGridDisasm.Font.Name    := 'Cascadia Mono';
  StringGridDisasm.Font.Height  := -18;
  StringGridDisasm.Font.Quality := fqDraft;

  { Memory grid: addr + 8 word columns }
  StringGridMemory.ColCount     := 9;
  StringGridMemory.FixedCols    := 1;
  StringGridMemory.FixedRows    := 0;
  StringGridMemory.ColWidths[0] := 90;    { address }
  StringGridMemory.ColWidths[1] := 60;    { word 1 }
  StringGridMemory.ColWidths[2] := 60;    { word 2 }
  StringGridMemory.ColWidths[3] := 60;    { etc. }
  StringGridMemory.ColWidths[4] := 60;
  StringGridMemory.ColWidths[5] := 60;
  StringGridMemory.ColWidths[6] := 60;
  StringGridMemory.ColWidths[7] := 60;
  StringGridMemory.ColWidths[8] := 60;
  StringGridMemory.Options      := StringGridMemory.Options - [goEditing];
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

  EditMemAddress.Text := 'FF0000';
  EditBP.Text         := 'FF0000';
  EditMhz.Text        := '10';

  RefreshRegs;
  RefreshDisasm;
  RefreshMem;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
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
begin
  StopCPU;
  FillChar(Mem, SizeOf(Mem), 0);
  CPU.Reset;
  FTermHead := 0;
  FTermTail := 0;
  MemoTerminal.Lines.Clear;
  FVideoMode := 0;
  pbVideo.Invalidate;
  if FileName <> '' then
  begin
    try
      MemLoadBin(FileName, RESET_VEC);
      FBinFile := FileName;
      LabelStatus.Caption := ExtractFileName(FileName) + '  —  Ready';
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
  OpenDialog.Filter     := 'K16 Binary (*.bin)|*.bin|All files (*.*)|*.*';
  OpenDialog.DefaultExt := 'bin';
  OpenDialog.Title      := 'Load K16 Binary';
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
         RunMode   := rmTimed;
         TargetMHz := mhz;
       end;
    2: begin  { Hz -- use timed with MHz=1 as close as we can }
         RunMode   := rmTimed;
         TargetMHz := 1;
       end;
  else  { Fast }
    RunMode := rmFast;
  end;
  StartCPU;
  FCPUThread.DoRun;
  LabelStatus.Caption := 'Running...';
end;

procedure TfrmMain.BtnStepClick(Sender: TObject);
begin
  if FBinFile = '' then begin ShowMessage('Load a .bin file first.'); Exit; end;
  StartCPU;
  FCPUThread.DoStop;
  FCPUThread.DoStep;
  LabelStatus.Caption := 'Stepping';
end;

procedure TfrmMain.BtnStopClick(Sender: TObject);
begin
  if FCPUThread <> nil then
  begin
    FCPUThread.DoStop;
    LabelStatus.Caption := 'Stopped';
  end;
end;

procedure TfrmMain.BtnResetClick(Sender: TObject);
begin
  LoadAndReset(FBinFile);
  LabelStatus.Caption := 'Reset';
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
    RefreshMem;
  end;
end;

{ ============================================================ }
{ Thread callbacks                                              }
{ ============================================================ }
procedure TfrmMain.OnCPUPanelUpdate(Sender: TObject);
begin
  RefreshRegs;
  RefreshDisasm;
  RefreshMem;
  DrainTermQueue;
  if FVideoMode > 0 then pbVideo.Invalidate;
end;

procedure TfrmMain.OnCPUHalt(Sender: TObject);
begin
  DrainTermQueue;
  RefreshRegs;
  RefreshDisasm;
  LabelStatus.Caption := Format('Halted  #$%2.2X  (%d cycles)',
    [CPU.HaltCode, CPU.CycleCount]);
end;

procedure TfrmMain.TmrRefresh(Sender: TObject);
begin
  DrainTermQueue;
  if FVideoMode > 0 then pbVideo.Invalidate;
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

procedure TfrmMain.RefreshDisasm;
var
  addr : TAddr;
  row  : Integer;
  used : Integer;
begin
  addr := CPU.PC;
  for row := 0 to StringGridDisasm.RowCount - 1 do
  begin
    if row = 0 then
      StringGridDisasm.Cells[0, row] := '►'
    else
      StringGridDisasm.Cells[0, row] := '';
    StringGridDisasm.Cells[1, row] := Disassemble(addr, used);
    Inc(addr, used);
    addr := addr and ADDR_MASK;
  end;
end;

procedure TfrmMain.RefreshMem;
var
  row, col : Integer;
  addr     : TAddr;
begin
  for row := 0 to StringGridMemory.RowCount - 1 do
  begin
    addr := (FMemBase + TAddr(row * 16)) and ADDR_MASK;
    StringGridMemory.Cells[0, row] := Format('$%6.6X', [addr]);
    for col := 1 to 8 do
      StringGridMemory.Cells[col, row] :=
        Format('%4.4X', [MemReadWord((addr + TAddr((col-1)*2)) and ADDR_MASK)]);
  end;
end;

procedure TfrmMain.DrainTermQueue;
var ch: Byte; line: string;
begin
  while FTermHead <> FTermTail do
  begin
    ch        := FTermQueue[FTermHead];
    FTermHead := (FTermHead + 1) and $FF;
    if ch = 13 then Continue;
    if ch = 10 then
      MemoTerminal.Lines.Add('')
    else
    begin
      if MemoTerminal.Lines.Count = 0 then MemoTerminal.Lines.Add('');
      line := MemoTerminal.Lines[MemoTerminal.Lines.Count-1] + Chr(ch);
      MemoTerminal.Lines[MemoTerminal.Lines.Count-1] := line;
    end;
  end;
end;

{ ============================================================ }
{ Video                                                         }
{ ============================================================ }
procedure TfrmMain.SetVideoMode(mode: Word);
begin
  FVideoMode := mode;
  pbVideo.Invalidate;
end;

procedure TfrmMain.PbVideoPaint(Sender: TObject);
var
  pb             : TPaintBox;
  W, H           : Integer;
  dest           : TRect;
  y, x, b, bit   : Integer;
  sl             : PByte;
  c              : LongWord;
  scale          : Double;
  rw, rh, rx, ry : Integer;

  function VGAColour(index: Byte): LongWord;
  const
    EGA: array[0..15] of LongWord = (
      $000000,$0000AA,$00AA00,$00AAAA,
      $AA0000,$AA00AA,$AA5500,$AAAAAA,
      $555555,$5555FF,$55FF55,$55FFFF,
      $FF5555,$FF55FF,$FFFF55,$FFFFFF);
  var r, g, bv: Integer;
  begin
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

begin
  pb := Sender as TPaintBox;
  W  := pb.Width; H := pb.Height;
  pb.Canvas.Brush.Color := clBlack;
  pb.Canvas.FillRect(Rect(0,0,W,H));
  if FVideoMode = 0 then Exit;

  if FVideoMode = 1 then
  begin
    FVideoBmp.Width       := 1024;
    FVideoBmp.Height      := 768;
    FVideoBmp.PixelFormat := pf32bit;
    for y := 0 to 767 do
    begin
      sl := FVideoBmp.ScanLine[y];
      for x := 0 to 127 do
      begin
        b := Mem[FB_BASE + y * 128 + x];
        for bit := 7 downto 0 do
        begin
          if (b shr bit) and 1 = 1 then
          begin sl^:=$FF;Inc(sl);sl^:=$FF;Inc(sl);sl^:=$FF;Inc(sl);sl^:=$FF;Inc(sl); end
          else
          begin sl^:=$00;Inc(sl);sl^:=$00;Inc(sl);sl^:=$00;Inc(sl);sl^:=$FF;Inc(sl); end;
        end;
      end;
    end;
  end
  else
  begin
    FVideoBmp.Width       := 640;
    FVideoBmp.Height      := 480;
    FVideoBmp.PixelFormat := pf32bit;
    for y := 0 to 479 do
    begin
      sl := FVideoBmp.ScanLine[y];
      for x := 0 to 639 do
      begin
        c   := VGAColour(Mem[FB_BASE + y * 640 + x]);
        sl^ := c and $FF;          Inc(sl);
        sl^ := (c shr 8)  and $FF; Inc(sl);
        sl^ := (c shr 16) and $FF; Inc(sl);
        sl^ := $FF;                Inc(sl);
      end;
    end;
  end;

  if (FVideoBmp.Width = 0) or (FVideoBmp.Height = 0) then Exit;
  scale := Min(W / FVideoBmp.Width, H / FVideoBmp.Height);
  rw    := Round(FVideoBmp.Width  * scale);
  rh    := Round(FVideoBmp.Height * scale);
  rx    := (W - rw) div 2;
  ry    := (H - rh) div 2;
  dest  := Rect(rx, ry, rx+rw, ry+rh);
  pb.Canvas.StretchDraw(dest, FVideoBmp);
end;

{ ============================================================ }
{ Terminal                                                      }
{ ============================================================ }
procedure TfrmMain.TermWrite(ch: Byte);
begin
  FTermQueue[FTermTail] := ch;
  FTermTail := (FTermTail + 1) and $FF;
end;

end.
