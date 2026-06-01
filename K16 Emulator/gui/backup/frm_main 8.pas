unit frm_main;
{
  K16 Emulator IDE -- Main Form
  UI designed in Lazarus Form Designer.
  Core emulator logic in core\ units -- no UI code there.
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
    Label1: TLabel;
    Label10: TLabel;
    Label11: TLabel;
    Label12: TLabel;
    Label13: TLabel;
    Label14: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    Label6: TLabel;
    Label7: TLabel;
    Label8: TLabel;
    Label9: TLabel;
    Memo1: TMemo;
    pbVideo: TPaintBox;
    Splitter1: TSplitter;
    StringGrid1: TStringGrid;
    StringGrid2: TStringGrid;
    { --------------------------------------------------------- }
    { Drop your components here in the form designer.           }
    { Lazarus will fill in declarations automatically.          }
    { --------------------------------------------------------- }

    { --- Suggested components to add: --- }
    { TPanel       pnlVideo        -- left, video output area   }
    { TPaintBox    pbVideo         -- inside pnlVideo           }
    { TPanel       pnlRegs         -- register display          }
    { TLabel       lblD0..lblD3    -- D register values         }
    { TLabel       lblX0..lblX3    -- X register values         }
    { TLabel       lblY0..lblY3    -- Y register values         }
    { TLabel       lblPC           -- program counter           }
    { TLabel       lblSR           -- status register flags     }
    { TLabel       lblCycles       -- cycle count               }
    { TLabel       lblStatus       -- running/stopped/halted    }
    { TStringGrid  sgDisasm        -- Bdisassembly view          }
    { TStringGrid  sgMem           -- memory inspector          }
    { TEdit        edMemAddr       -- memory address entry      }
    { TMemo        memoTerm        -- terminal output           }
    { TButton      btnLoad         -- load .bin file            }
    { TButton      btnRun          -- run                       }
    { TButton      btnStep         -- step one instruction      }
    { TButton      btnStop         -- stop/pause                }
    { TButton      btnReset        -- reset CPU                 }
    { TEdit        edMHz           -- MHz throttle (0=fast)     }
    { TCheckBox    chkBP           -- breakpoint enable         }
    { TEdit        edBP            -- breakpoint address        }
    { TTimer       tmrRefresh      -- periodic panel refresh    }
    { TOpenDialog  dlgOpen         -- file open dialog          }

    { --- Wire these events in the Object Inspector: --- }
    { btnLoad.OnClick   -> BtnLoadClick   }
    { btnRun.OnClick    -> BtnRunClick    }
    { btnStep.OnClick   -> BtnStepClick   }
    { btnStop.OnClick   -> BtnStopClick   }
    { btnReset.OnClick  -> BtnResetClick  }
    { chkBP.OnChange    -> ChkBPChange    }
    { edBP.OnChange     -> EdBPChange     }
    { edMemAddr.OnChange-> EdMemAddrChange}
    { pbVideo.OnPaint   -> PbVideoPaint   }
    { tmrRefresh.OnTimer-> TmrRefresh     }
    { Form.OnCreate     -> FormCreate     }
    { Form.OnDestroy    -> FormDestroy    }

    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure BtnLoadClick(Sender: TObject);
    procedure BtnRunClick(Sender: TObject);
    procedure BtnStepClick(Sender: TObject);
    procedure BtnStopClick(Sender: TObject);
    procedure BtnResetClick(Sender: TObject);
    procedure ChkBPChange(Sender: TObject);
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

    { Terminal byte queue -- CPU thread writes, UI timer drains }
    FTermQueue  : array[0..255] of Byte;
    FTermHead   : Integer;
    FTermTail   : Integer;

    { CPU thread callbacks -- called on UI thread via Synchronize }
    procedure OnCPUPanelUpdate(Sender: TObject);
    procedure OnCPUHalt(Sender: TObject);

    { Internal helpers }
    procedure StartCPU;
    procedure StopCPU;
    procedure LoadAndReset(const FileName: string);

    { Refresh individual panels -- call from timer or Synchronize }
    procedure RefreshRegs;
    procedure RefreshDisasm;
    procedure RefreshMem;
    procedure DrainTermQueue;

    { IO callbacks }
    procedure TermWrite(ch: Byte);

  public
    { Called by VideoModeHook (global proc) when $C00010 is written }
    procedure SetVideoMode(mode: Word);
  end;

{ Global IOWriteHook -- plain proc pointer, set in FormCreate }
procedure VideoModeHook(addr: TAddr; value: TWord);

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

{ ============================================================ }
{ Global video mode hook                                        }
{ Must be a plain procedure, not a method (proc ptr constraint) }
{ ============================================================ }
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
  { Wire IO handler }
  FGUIHandler.Init;
  FGUIHandler.TermOutput := TermWrite;
  IO          := @FGUIHandler;
  IOWriteHook := VideoModeHook;

  { Init emulator }
  FillChar(Mem, SizeOf(Mem), 0);
  InitDispatch;
  CPU.Reset;

  { Init state }
  FVideoBmp  := TBitmap.Create;
  FVideoMode := 0;
  FMemBase   := RESET_VEC;
  FBinFile   := '';
  FTermHead  := 0;
  FTermTail  := 0;

  { Initial panel refresh }
  RefreshRegs;
  RefreshDisasm;
  RefreshMem;

  { --------------------------------------------------------- }
  { Set your component initial properties here if needed, e.g: }
  {   sgDisasm.ColWidths[0] := 18;                            }
  {   sgDisasm.ColWidths[1] := 500;                           }
  {   sgMem.ColWidths[0] := 80;                               }
  {   edMHz.Text := '0';                                      }
  {   edMemAddr.Text := 'FF0000';                             }
  {   edBP.Text := 'FF0000';                                  }
  { --------------------------------------------------------- }
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
    FCPUThread.DoStep;   { unblock if waiting }
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
  { --------------------------------------------------------- }
  { Clear your terminal memo here, e.g.:  memoTerm.Clear;    }
  { --------------------------------------------------------- }
  if FileName <> '' then
  begin
    try
      MemLoadBin(FileName, RESET_VEC);
      FBinFile := FileName;
      { --------------------------------------------------------- }
      { Update status label, e.g.:                               }
      {   lblStatus.Caption := ExtractFileName(FileName)+' loaded';}
      { --------------------------------------------------------- }
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
{ Button handlers                                               }
{ ============================================================ }
procedure TfrmMain.BtnLoadClick(Sender: TObject);
begin
  StopCPU;
  { --------------------------------------------------------- }
  { Use your dlgOpen dialog, e.g.:                            }
  {   dlgOpen.Filter := 'K16 Binary (*.bin)|*.bin';          }
  {   if dlgOpen.Execute then                                 }
  {     LoadAndReset(dlgOpen.FileName);                       }
  { --------------------------------------------------------- }
end;

procedure TfrmMain.BtnRunClick(Sender: TObject);
var mhz: Integer;
begin
  if FBinFile = '' then begin ShowMessage('Load a .bin file first.'); Exit; end;
  { --------------------------------------------------------- }
  { Read MHz from your edit, e.g.:                           }
  {   mhz := StrToIntDef(edMHz.Text, 0);                    }
  { --------------------------------------------------------- }
  mhz := 0;
  if mhz > 0 then begin RunMode := rmTimed; TargetMHz := mhz; end
  else RunMode := rmFast;
  StartCPU;
  FCPUThread.DoRun;
  { lblStatus.Caption := 'Running...'; }
end;

procedure TfrmMain.BtnStepClick(Sender: TObject);
begin
  if FBinFile = '' then begin ShowMessage('Load a .bin file first.'); Exit; end;
  StartCPU;
  FCPUThread.DoStop;
  FCPUThread.DoStep;
  { lblStatus.Caption := 'Stepping'; }
end;

procedure TfrmMain.BtnStopClick(Sender: TObject);
begin
  if FCPUThread <> nil then
  begin
    FCPUThread.DoStop;
    { lblStatus.Caption := 'Stopped'; }
  end;
end;

procedure TfrmMain.BtnResetClick(Sender: TObject);
begin
  LoadAndReset(FBinFile);
  { lblStatus.Caption := 'Reset'; }
end;

procedure TfrmMain.ChkBPChange(Sender: TObject);
begin
  { --------------------------------------------------------- }
  { BreakEnabled := chkBP.Checked;                           }
  { --------------------------------------------------------- }
end;

procedure TfrmMain.EdBPChange(Sender: TObject);
var v: Int64;
begin
  { --------------------------------------------------------- }
  { if TryStrToInt64('$'+Trim(edBP.Text), v) then            }
  {   BreakAddr := v and ADDR_MASK;                          }
  { --------------------------------------------------------- }
end;

procedure TfrmMain.EdMemAddrChange(Sender: TObject);
var v: Int64;
begin
  { --------------------------------------------------------- }
  { if TryStrToInt64('$'+Trim(edMemAddr.Text), v) then       }
  {   FMemBase := v and ADDR_MASK;                           }
  { RefreshMem;                                              }
  { --------------------------------------------------------- }
end;

{ ============================================================ }
{ Thread callbacks (Synchronize -> UI thread)                  }
{ ============================================================ }
procedure TfrmMain.OnCPUPanelUpdate(Sender: TObject);
begin
  RefreshRegs;
  RefreshDisasm;
  RefreshMem;
  DrainTermQueue;
  { if FVideoMode > 0 then pbVideo.Invalidate; }
end;

procedure TfrmMain.OnCPUHalt(Sender: TObject);
begin
  DrainTermQueue;
  RefreshRegs;
  RefreshDisasm;
  { lblStatus.Caption := Format('Halted  code=$%2.2X  cycles=%d',
      [CPU.HaltCode, CPU.CycleCount]); }
end;

{ ============================================================ }
{ Timer -- periodic refresh and terminal drain                  }
{ ============================================================ }
procedure TfrmMain.TmrRefresh(Sender: TObject);
begin
  DrainTermQueue;
  { if FVideoMode > 0 then pbVideo.Invalidate; }
end;

{ ============================================================ }
{ Panel refresh                                                 }
{ ============================================================ }
procedure TfrmMain.RefreshRegs;
begin
  { --------------------------------------------------------- }
  { Update your register labels here, e.g.:                  }
  {   lblD0.Caption := Format('D0=$%4.4X', [CPU.D[0]]);     }
  {   lblD1.Caption := Format('D1=$%4.4X', [CPU.D[1]]);     }
  {   lblD2.Caption := Format('D2=$%4.4X', [CPU.D[2]]);     }
  {   lblD3.Caption := Format('D3=$%4.4X', [CPU.D[3]]);     }
  {   lblX0.Caption := Format('X0=$%4.4X', [CPU.X[0]]);     }
  {   lblX1.Caption := Format('X1=$%4.4X', [CPU.X[1]]);     }
  {   lblX2.Caption := Format('X2=$%4.4X', [CPU.X[2]]);     }
  {   lblX3.Caption := Format('X3=$%4.4X', [CPU.X[3]]);     }
  {   lblY0.Caption := Format('Y0=$%2.2X',  [CPU.Y[0]]);    }
  {   lblY1.Caption := Format('Y1=$%2.2X',  [CPU.Y[1]]);    }
  {   lblY2.Caption := Format('Y2=$%2.2X',  [CPU.Y[2]]);    }
  {   lblY3.Caption := Format('Y3=$%2.2X',  [CPU.Y[3]]);    }
  {   lblPC.Caption     := Format('PC=$%6.6X', [CPU.PC]);   }
  {   lblSR.Caption     := 'SR=' + FormatFlags;              }
  {   lblCycles.Caption := Format('Cycles=%d',[CPU.CycleCount]);}
  { --------------------------------------------------------- }
end;

procedure TfrmMain.RefreshDisasm;
const
  ROWS = 20;   { match your sgDisasm.RowCount }
var
  addr : TAddr;
  row  : Integer;
  used : Integer;
begin
  { --------------------------------------------------------- }
  { Disassemble from PC downward into sgDisasm rows, e.g.:   }
  addr := CPU.PC;
  for row := 0 to ROWS - 1 do
  begin
    { sgDisasm.Cells[0, row] := IfThen(row=0, '►', '');     }
    { sgDisasm.Cells[1, row] := Disassemble(addr, used);    }
    Disassemble(addr, used);   { call so addr advances }
    Inc(addr, used);
    addr := addr and ADDR_MASK;
  end;
  { --------------------------------------------------------- }
end;

procedure TfrmMain.RefreshMem;
var
  row, col : Integer;
  addr     : TAddr;
begin
  { --------------------------------------------------------- }
  { Fill sgMem rows with hex words, e.g. (8 words per row):  }
  { for row := 0 to sgMem.RowCount-1 do                      }
  { begin                                                     }
  {   addr := (FMemBase + TAddr(row*16)) and ADDR_MASK;      }
  {   sgMem.Cells[0,row] := Format('$%6.6X',[addr]);         }
  {   for col := 1 to 8 do                                   }
  {     sgMem.Cells[col,row] := Format('%4.4X',              }
  {       [MemReadWord((addr+TAddr((col-1)*2)) and ADDR_MASK)]);  }
  { end;                                                      }
  { --------------------------------------------------------- }
end;

procedure TfrmMain.DrainTermQueue;
begin
  { --------------------------------------------------------- }
  { Drain FTermQueue into memoTerm, e.g.:                    }
  while FTermHead <> FTermTail do
  begin
    { var ch := FTermQueue[FTermHead];                        }
    { FTermHead := (FTermHead+1) and $FF;                    }
    { if ch = 13 then Continue;                              }
    { if ch = 10 then memoTerm.Lines.Add('')                 }
    { else begin                                             }
    {   if memoTerm.Lines.Count = 0 then memoTerm.Lines.Add('');}
    {   memoTerm.Lines[memoTerm.Lines.Count-1] :=           }
    {     memoTerm.Lines[memoTerm.Lines.Count-1] + Chr(ch); }
    { end;                                                   }
    Break;  { remove this Break once you've added memoTerm }
  end;
  { --------------------------------------------------------- }
end;

{ ============================================================ }
{ Video                                                         }
{ ============================================================ }
procedure TfrmMain.SetVideoMode(mode: Word);
begin
  FVideoMode := mode;
  { pbVideo.Invalidate; }
end;

procedure TfrmMain.PbVideoPaint(Sender: TObject);
{ Assign this to pbVideo.OnPaint }
var
  pb         : TPaintBox;
  W, H       : Integer;
  dest       : TRect;
  y, x, b, bit: Integer;
  sl         : PByte;
  c          : LongWord;
  scale      : Double;
  rw, rh, rx, ry: Integer;

  { Standard 6x6x6 VGA colour cube, indices 16-231 }
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
      r := (index div 36) * 51;
      g := ((index div 6) mod 6) * 51;
      bv:= (index mod 6) * 51;
      Result := (LongWord(r) shl 16) or (LongWord(g) shl 8) or bv;
    end else
    begin
      bv := 8 + (index - 232) * 10;
      Result := (LongWord(bv) shl 16) or (LongWord(bv) shl 8) or bv;
    end;
  end;

begin
  pb := Sender as TPaintBox;
  W  := pb.Width; H := pb.Height;
  pb.Canvas.Brush.Color := clBlack;
  pb.Canvas.FillRect(Rect(0,0,W,H));
  if FVideoMode = 0 then Exit;

  { Build native bitmap from framebuffer memory }
  if FVideoMode = 1 then
  begin
    { 1bpp 1024x768 -- MSB = leftmost pixel, stride = 128 bytes }
    FVideoBmp.Width  := 1024;
    FVideoBmp.Height := 768;
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
    { 8bpp 640x480 -- one byte per pixel }
    FVideoBmp.Width  := 640;
    FVideoBmp.Height := 480;
    FVideoBmp.PixelFormat := pf32bit;
    for y := 0 to 479 do
    begin
      sl := FVideoBmp.ScanLine[y];
      for x := 0 to 639 do
      begin
        c    := VGAColour(Mem[FB_BASE + y * 640 + x]);
        sl^  := c and $FF;          Inc(sl);  { B }
        sl^  := (c shr 8) and $FF;  Inc(sl);  { G }
        sl^  := (c shr 16) and $FF; Inc(sl);  { R }
        sl^  := $FF;                 Inc(sl);  { A }
      end;
    end;
  end;

  { Letterbox-scale into paintbox, preserving aspect ratio }
  if (FVideoBmp.Width = 0) or (FVideoBmp.Height = 0) then Exit;
  scale := Min(W / FVideoBmp.Width, H / FVideoBmp.Height);
  rw := Round(FVideoBmp.Width  * scale);
  rh := Round(FVideoBmp.Height * scale);
  rx := (W - rw) div 2;
  ry := (H - rh) div 2;
  dest := Rect(rx, ry, rx+rw, ry+rh);
  pb.Canvas.StretchDraw(dest, FVideoBmp);
end;

{ ============================================================ }
{ Terminal -- called from CPU thread (lock-free SPSC queue)    }
{ ============================================================ }
procedure TfrmMain.TermWrite(ch: Byte);
begin
  FTermQueue[FTermTail] := ch;
  FTermTail := (FTermTail + 1) and $FF;
end;

end.
