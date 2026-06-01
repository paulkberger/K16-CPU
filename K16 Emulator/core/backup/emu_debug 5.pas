unit emu_debug;
{
  K16 Emulator -- Debug Utilities (core, no UI dependency)
  Part of the K16 homebrew CPU project.
}
{$mode Delphi}
{$H+}
interface
uses SysUtils, emu_types, emu_mem, emu_cpu;

function FormatFlags: string;
function FormatRegs: string;
function Disassemble(addr: TAddr; out BytesUsed: Integer): string;
function FormatMem(addr: TAddr; words: Word): string;

implementation

const
  DnName : array[0..3] of string = ('D0','D1','D2','D3');
  XnName : array[0..3] of string = ('X0','X1','X2','X3');
  XYName : array[0..3] of string = ('XY0','XY1','XY2','XY3');
  CcName : array[0..7] of string = ('EQ','NE','CS','CC','LT','GT','GE','LE');
  AluName: array[0..8] of string =
    ('ADD','ADC','SUB','SBC','AND','OR','XOR','NOT','CMP');

function FormatFlags: string;
begin
  Result := '[';
  if CPU.SR.Flags.C then Result := Result + 'C' else Result := Result + '-';
  if CPU.SR.Flags.Z then Result := Result + 'Z' else Result := Result + '-';
  if CPU.SR.Flags.N then Result := Result + 'N' else Result := Result + '-';
  if CPU.SR.Flags.V then Result := Result + 'V' else Result := Result + '-';
  Result := Result + '] ';
  if CPU.SR.IE then Result := Result + 'IE' else Result := Result + '--';
  Result := Result + Format(' L%d', [CPU.SR.Level]);
end;

function FormatRegs: string;
begin
  Result :=
    Format('D0=$%4.4X D1=$%4.4X D2=$%4.4X D3=$%4.4X',
           [CPU.D[0],CPU.D[1],CPU.D[2],CPU.D[3]]) + LineEnding +
    Format('X0=$%4.4X X1=$%4.4X X2=$%4.4X X3=$%4.4X',
           [CPU.X[0],CPU.X[1],CPU.X[2],CPU.X[3]]) + LineEnding +
    Format('Y0=$%2.2X   Y1=$%2.2X   Y2=$%2.2X   Y3=$%2.2X',
           [CPU.Y[0],CPU.Y[1],CPU.Y[2],CPU.Y[3]]) + LineEnding +
    Format('PC=$%6.6X  SR=%s  Cycles=%d',
           [CPU.PC, FormatFlags, CPU.CycleCount]);
end;

function Disassemble(addr: TAddr; out BytesUsed: Integer): string;
var
  iw, op, mode, opr: Word;
  imm: TWord;
  Dd, Ds, Xs, cond, bank, li, rf4: Byte;
  off: Integer;
  mnem, regname: string;

  function Rf4Name(r: Byte): string;
  begin
    case r of
      0..3:  Result := DnName[r];
      4..7:  Result := XnName[r-4];
      8..11: Result := Format('Y%d',[r-8]);
      12:    Result := 'ORDB';
      13:    Result := 'SR';
      14:    Result := 'PCH';
      15:    Result := 'PCL';
    else     Result := Format('?%d',[r]);
    end;
  end;

begin
  iw   := MemReadWord(addr);
  op   := (iw shr 11) and $1F;
  mode := (iw shr 9)  and $03;
  opr  := iw and $01FF;
  BytesUsed := 2;
  Result := Format('$%6.6X  %4.4X  ', [addr, iw]);

  case op of
    $00: { MISC }
      case mode of
        0: Result := Result + 'NOP';
        1: Result := Result + Format('HALT #$%2.2X', [opr and $FF]);
        3: begin
             Dd := (opr shr 5) and $0F; Ds := (opr shr 1) and $0F;
             if Dd = Ds then Result := Result + Format('NEG %s', [Rf4Name(Dd)])
             else            Result := Result + Format('NEG %s, %s', [Rf4Name(Dd), Rf4Name(Ds)]);
           end;
      else Result := Result + 'MISC???';
      end;

    $01: { LOOKUP }
      begin
        Dd := mode and 3;  { destination D register from IR[10:9] }
        case opr and $FF of
          $E0: mnem:='SHL';    $E2: mnem:='SHR';    $E4: mnem:='ASR';
          $E6: mnem:='ROL';    $E8: mnem:='ROR';    $EA: mnem:='SWAPB';
          $EC: mnem:='HIGH';   $EE: mnem:='LOW';
          $F0: mnem:='SHR4';   $F2: mnem:='SHL4';   $F4: mnem:='ASR4';
          $F6: mnem:='ASR8';   $F8: mnem:='MULB';   $FA: mnem:='RECIP';
        else   mnem:=Format('LOOKUP#$%2.2X',[opr and $FF]);
        end;
        Result := Result + Format('%s %s', [mnem, DnName[Dd]]);
      end;

    $02: { INC/DEC }
      begin
        Xs := (opr shr 5) and 3;
        if mode = 0 then Result := Result + Format('INC %s',[XYName[Xs]])
        else             Result := Result + Format('DEC %s',[XYName[Xs]]);
      end;

    $03: { LEA }
      begin
        { dst XY = IR[8:7]=(opr shr 7)&3; src XY = IR[6:5]=(opr shr 5)&3 }
        { D reg for indexed = IR[4:3]=(opr shr 3)&3; imm5 = IR[4:0]=opr&$1F }
        Dd := (opr shr 7) and 3; Xs := (opr shr 5) and 3;
        case mode of
          0: if (opr and $1F) = 0 then
               Result := Result + Format('LEA %s, [%s]',    [XYName[Dd],XYName[Xs]])
             else
               Result := Result + Format('LEA %s, [%s+D%d]',[XYName[Dd],XYName[Xs],(opr shr 3) and 3]);
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LEA %s, [PC+$%4.4X]',[XYName[Dd],imm]); end;
          2: Result := Result + Format('LEA %s, [%s+#%d]',  [XYName[Dd],XYName[Xs],opr and $1F]);
          3: Result := Result + Format('LEA %s, [%s]',      [XYName[Dd],XYName[Xs]]);
        end;
      end;

    $04: { Scc }
      begin
        Dd:=(opr shr 1) and $0F; cond:=(opr shr 5) and 7;
        Result := Result + Format('S%s %s',[CcName[cond],Rf4Name(Dd)]);
      end;

    $05: { MOVE / SWAP }
      begin
        case mode of
          0: begin { MOVE dst(4bit), src(4bit) — src at bits 4:1 (IR bit 0 always 0) }
               rf4 := (opr shr 5) and $0F;
               li  := (opr shr 1) and $0F;
               Result := Result + Format('MOVE %s, %s',[Rf4Name(rf4), Rf4Name(li)]);
             end;
          1: begin { MOVE dst(4bit), src(4bit) }
               rf4 := (opr shr 5) and $0F;
               li  := (opr shr 1) and $0F;
               Result := Result + Format('MOVE %s, %s',[Rf4Name(rf4), Rf4Name(li)]);
             end;
          2,3: begin { SWAP reg, reg }
               rf4 := (opr shr 5) and $0F;
               li  := (opr shr 1) and $0F;
               Result := Result + Format('SWAP %s, %s',[Rf4Name(rf4), Rf4Name(li)]);
             end;
        end;
      end;

    $06: { PUSH }
    $06: { PUSH }
      begin
        Xs := (opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('PUSH %s, %s',[Rf4Name((opr shr 5) and $0F),XYName[Xs]]);
          1: Result := Result + Format('PUSH D-grp, %s',[XYName[Xs]]);
          2: Result := Result + Format('PUSH %s, %s',[XYName[(opr shr 5) and 3],XYName[Xs]]);
          3: Result := Result + Format('PUSH %s, %s',[Rf4Name((opr shr 5) and $0F),XYName[Xs]]);
        end;
      end;

    $07: { POP }
      begin
        Xs := (opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('POP %s, %s',[Rf4Name((opr shr 5) and $0F),XYName[Xs]]);
          1: Result := Result + Format('POP D-grp, %s',[XYName[Xs]]);
          2: Result := Result + Format('POP %s, %s',[XYName[(opr shr 5) and 3],XYName[Xs]]);
          3: Result := Result + Format('POPD %s',[XYName[Xs]]);
        end;
      end;

    $08,$09,$0A,$0B,$0C,$0D,$0E,$10: { ALU except NOT + CMP }
      begin
        Dd:=(opr shr 5) and $0F; Ds:=(opr shr 1) and $0F; li:=op-$08;
        Xs:=(opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('%s %s, %s',      [AluName[li],Rf4Name(Dd),Rf4Name(Ds)]);
          1: Result := Result + Format('%s %s, [%s]',    [AluName[li],Rf4Name(Dd),XYName[Xs]]);
          2: Result := Result + Format('%s %s, #%d',     [AluName[li],Rf4Name((opr shr 5) and $0F),opr and $1F]);
          3: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('%s %s, #$%4.4X',[AluName[li],Rf4Name((opr shr 5) and $0F),imm]); end;
        end;
      end;

    $0F: { NOT - special handling for correct operand routing }
      begin
        Dd:=(opr shr 5) and $0F; Ds:=(opr shr 1) and $0F;
        Xs:=(opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('NOT %s, %s',      [Rf4Name(Dd),Rf4Name(Ds)]);      { NOT dest, src }
          1: Result := Result + Format('NOT %s, [%s]',    [Rf4Name(Dd),XYName[Xs]]);       { NOT dest, [XY] }
          2: Result := Result + Format('NOT %s',          [Rf4Name(Dd)]);                  { NOT dest (in-place) }
          3: begin imm:=MemReadWord(addr+2); BytesUsed:=4;                                  { NOT dest, #imm16 }
               Result := Result + Format('NOT %s, #$%4.4X',[Rf4Name(Dd),imm]); end;
        end;
      end;

    $11: { Bcc }
      begin
        cond := (opr shr 5) and 7;
        case mode of
          0: begin { short conditional }
               off := opr and $1F;
               Result := Result + Format('B%s +%d',[CcName[cond],off]);
             end;
          1: begin { long conditional }
               imm := MemReadWord(addr+2); BytesUsed := 4; off := SmallInt(imm);
               Result := Result + Format('B%s $%6.6X',
                 [CcName[cond], TAddr(Integer(addr+4)+off) and ADDR_MASK]);
             end;
          2: begin { BRA short }
               off := opr and $1F;
               Result := Result + Format('BRA +%d',[off]);
             end;
          3: begin { BRA long }
               imm := MemReadWord(addr+2); BytesUsed := 4; off := SmallInt(imm);
               Result := Result + Format('BRA $%6.6X',
                 [TAddr(Integer(addr+4)+off) and ADDR_MASK]);
             end;
        end;
      end;

    $12: { JMP }
      case mode of
        0: begin imm:=MemReadWord(addr+2); BytesUsed:=4; bank:=opr and $FF;
             Result := Result + Format('JMP24 $%2.2X%4.4X',[bank,imm]); end;
        1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('JMP16 $%4.4X',[imm]); end;
        2: Result := Result + Format('JMPT %s, %s',
             [XYName[(opr shr 5) and 3], DnName[(opr shr 7) and 3]]);
        3: Result := Result + Format('JMPXY %s',[XYName[(opr shr 5) and 3]]);
      end;

    $13: { CALL }
      case mode of
        0: begin imm:=MemReadWord(addr+2); BytesUsed:=4; bank:=opr and $FF;
             Result := Result + Format('CALL24 $%2.2X%4.4X',[bank,imm]); end;
        1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('CALL16 $%4.4X',[imm]); end;
        2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('CALLR %+d',[SmallInt(imm)]); end;
        3: Result := Result + Format('CALLXY %s',[XYName[(opr shr 5) and 3]]);
      end;

    $14,$15: { LOADD, LOADB -- mode 1 = [XYn+Dn] }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        if op = $14 then mnem := 'LOADD' else mnem := 'LOADB';
        case mode of
          0: Result := Result + Format('%s %s, [%s]',     [mnem,DnName[Dd],XYName[Xs]]);
          1: Result := Result + Format('%s %s, [%s+D%d]', [mnem,DnName[Dd],XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('%s %s, [PC+$%4.4X]',[mnem,DnName[Dd],imm]); end;
          3: Result := Result + Format('%s %s, [%s+#%d]', [mnem,DnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $16: { LOADX -- mode 1 = LOADI Xn, #imm16 }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('LOADX %s, [%s]',      [XnName[Dd],XYName[Xs]]);
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADI %s, #$%4.4X', [XnName[Dd],imm]); end;
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADX %s, [PC+$%4.4X]',[XnName[Dd],imm]); end;
          3: Result := Result + Format('LOADX %s, [%s+#%d]',  [XnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $17: { LOADY -- mode 1 = LOADI Yn, #imm8 }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('LOADY Y%d, [%s]',     [Dd,XYName[Xs]]);
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADI Y%d, #$%2.2X',[Dd,imm and $FF]); end;
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADY Y%d, [PC+$%4.4X]',[Dd,imm]); end;
          3: Result := Result + Format('LOADY Y%d, [%s+#%d]', [Dd,XYName[Xs],opr and $1F]);
        end;
      end;

    $18: { LOADI }
      begin
        { 4-bit reg field at bits[8:5]: D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11,
          ORDB=12, SR=13, PCH=14, PCL=15 }
        rf4 := (opr shr 5) and $0F;
        regname := Rf4Name(rf4);
        case mode of
          0: begin  { IMM5 }
               { Pretty-print SEC/CLC aliases as hints after the LOADI form }
               if (rf4 = 13) and ((opr and $1F) = 1) then
                 Result := Result + 'LOADI SR, #$01 (SEC)'
               else if (rf4 = 13) and ((opr and $1F) = 0) then
                 Result := Result + 'LOADI SR, #$00 (CLC)'
               else
                 Result := Result + Format('LOADI %s, #%d',[regname, opr and $1F]);
             end;
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADI %s, #$%4.4X',[regname, imm]); end;
          2: Result := Result + Format('LOADXY %s, [%s]',
               [XYName[(opr shr 7) and 3],   { dest: bits[8:7] }
                XYName[(opr shr 5) and 3]]);  { src:  bits[6:5], 1 word total }
          3: begin imm := MemReadWord(addr+2); BytesUsed := 4;
               if (opr shr 3) and 1 = 1 then
                 Result := Result + Format('LOADPB %s, Y%d, [#$%4.4X]',
                   [Rf4Name(rf4), (opr shr 1) and 3, imm])
               else
                 Result := Result + Format('LOADP %s, Y%d, [#$%4.4X]',
                   [Rf4Name(rf4), (opr shr 1) and 3, imm]);
             end;
        end;
      end;

    $19,$1A: { STORED, STOREB -- mode 1 = [XYn+Dn] }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        if op = $19 then mnem := 'STORED' else mnem := 'STOREB';
        case mode of
          0: Result := Result + Format('%s %s, [%s]',     [mnem,DnName[Dd],XYName[Xs]]);
          1: Result := Result + Format('%s %s, [%s+D%d]', [mnem,DnName[Dd],XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('%s %s, [PC+$%4.4X]',[mnem,DnName[Dd],imm]); end;
          3: Result := Result + Format('%s %s, [%s+#%d]', [mnem,DnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $1B: { STOREX }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('STOREX %s, [%s]',     [XnName[Dd],XYName[Xs]]);
          1: Result := Result + Format('STOREX %s, [%s+D%d]', [XnName[Dd],XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('STOREX %s, [PC+$%4.4X]',[XnName[Dd],imm]); end;
          3: Result := Result + Format('STOREX %s, [%s+#%d]', [XnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $1C: { STOREY }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('STOREY Y%d, [%s]',     [Dd,XYName[Xs]]);
          1: Result := Result + Format('STOREY Y%d, [%s+D%d]', [Dd,XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('STOREY Y%d, [PC+$%4.4X]',[Dd,imm]); end;
          3: Result := Result + Format('STOREY Y%d, [%s+#%d]', [Dd,XYName[Xs],opr and $1F]);
        end;
      end;

    $1D: { STOREI }
      case mode of
        0: Result := Result + Format('STOREI #%d, [%s]',
             [opr and $1F, XYName[(opr shr 5) and 3]]);
        1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('STOREI #$%4.4X, [%s]',
               [imm,XYName[(opr shr 5) and 3]]); end;
        2: Result := Result + Format('STOREXY [%s], %s',
             [XYName[(opr shr 7) and 3],XYName[(opr shr 5) and 3]]);
        3: begin imm := MemReadWord(addr+2); BytesUsed := 4;
             if (opr shr 3) and 1 = 1 then
               Result := Result + Format('STOREPB %s, Y%d, [#$%4.4X]',
                 [Rf4Name((opr shr 5) and $0F), (opr shr 1) and 3, imm])
             else
               Result := Result + Format('STOREP %s, Y%d, [#$%4.4X]',
                 [Rf4Name((opr shr 5) and $0F), (opr shr 1) and 3, imm]);
           end;
      end;

    $1E: { TRAP / RET }
      if mode = 0 then
        Result := Result + Format('TRAP #%d',[(opr and $FF) shr 1])
      else if mode = 3 then
      begin
        if opr and $1F = 0 then Result := Result + 'RET'
        else Result := Result + Format('RET #%dw',[opr and $1F]);
      end else
        Result := Result + 'TRAP/RET???';

    $1F: { INT }
      case mode of
        0: Result := Result + 'DINT';
        1: Result := Result + 'EINT';
        2: Result := Result + 'RTI';
        3: Result := Result + 'INT';
      end;

  else
    Result := Result + Format('??? op=$%2.2X mode=%d',[op,mode]);
  end;
end;

function FormatMem(addr: TAddr; words: Word): string;
var i: Integer; a: TAddr;
begin
  Result := '';
  for i := 0 to words-1 do
  begin
    a := (addr + TAddr(i*2)) and ADDR_MASK;
    if i mod 8 = 0 then
    begin
      if i > 0 then Result := Result + LineEnding;
      Result := Result + Format('$%6.6X:',[a]);
    end;
    Result := Result + Format(' %4.4X',[MemReadWord(a)]);
  end;
end;

unit emu_debug;
{
  K16 Emulator -- Debug Utilities (core, no UI dependency)
  Part of the K16 homebrew CPU project.
}
{$mode Delphi}
{$H+}
interface
uses SysUtils, emu_types, emu_mem, emu_cpu;

function FormatFlags: string;
function FormatRegs: string;
function Disassemble(addr: TAddr; out BytesUsed: Integer): string;
function FormatMem(addr: TAddr; words: Word): string;

implementation

const
  DnName : array[0..3] of string = ('D0','D1','D2','D3');
  XnName : array[0..3] of string = ('X0','X1','X2','X3');
  XYName : array[0..3] of string = ('XY0','XY1','XY2','XY3');
  CcName : array[0..7] of string = ('EQ','NE','CS','CC','LT','GT','GE','LE');
  AluName: array[0..8] of string =
    ('ADD','ADC','SUB','SBC','AND','OR','XOR','NOT','CMP');

function FormatFlags: string;
begin
  Result := '[';
  if CPU.SR.Flags.C then Result := Result + 'C' else Result := Result + '-';
  if CPU.SR.Flags.Z then Result := Result + 'Z' else Result := Result + '-';
  if CPU.SR.Flags.N then Result := Result + 'N' else Result := Result + '-';
  if CPU.SR.Flags.V then Result := Result + 'V' else Result := Result + '-';
  Result := Result + '] ';
  if CPU.SR.IE then Result := Result + 'IE' else Result := Result + '--';
  Result := Result + Format(' L%d', [CPU.SR.Level]);
end;

function FormatRegs: string;
begin
  Result :=
    Format('D0=$%4.4X D1=$%4.4X D2=$%4.4X D3=$%4.4X',
           [CPU.D[0],CPU.D[1],CPU.D[2],CPU.D[3]]) + LineEnding +
    Format('X0=$%4.4X X1=$%4.4X X2=$%4.4X X3=$%4.4X',
           [CPU.X[0],CPU.X[1],CPU.X[2],CPU.X[3]]) + LineEnding +
    Format('Y0=$%2.2X   Y1=$%2.2X   Y2=$%2.2X   Y3=$%2.2X',
           [CPU.Y[0],CPU.Y[1],CPU.Y[2],CPU.Y[3]]) + LineEnding +
    Format('PC=$%6.6X  SR=%s  Cycles=%d',
           [CPU.PC, FormatFlags, CPU.CycleCount]);
end;

function Disassemble(addr: TAddr; out BytesUsed: Integer): string;
var
  iw, op, mode, opr: Word;
  imm: TWord;
  Dd, Ds, Xs, cond, bank, li, rf4: Byte;
  off: Integer;
  mnem, regname: string;

  function Rf4Name(r: Byte): string;
  begin
    case r of
      0..3:  Result := DnName[r];
      4..7:  Result := XnName[r-4];
      8..11: Result := Format('Y%d',[r-8]);
      12:    Result := 'ORDB';
      13:    Result := 'SR';
      14:    Result := 'PCH';
      15:    Result := 'PCL';
    else     Result := Format('?%d',[r]);
    end;
  end;

begin
  iw   := MemReadWord(addr);
  op   := (iw shr 11) and $1F;
  mode := (iw shr 9)  and $03;
  opr  := iw and $01FF;
  BytesUsed := 2;
  Result := Format('$%6.6X  %4.4X  ', [addr, iw]);

  case op of
    $00: { MISC }
      case mode of
        0: Result := Result + 'NOP';
        1: Result := Result + Format('HALT #$%2.2X', [opr and $FF]);
        3: begin
             Dd := (opr shr 5) and $0F; Ds := (opr shr 1) and $0F;
             if Dd = Ds then Result := Result + Format('NEG %s', [Rf4Name(Dd)])
             else            Result := Result + Format('NEG %s, %s', [Rf4Name(Dd), Rf4Name(Ds)]);
           end;
      else Result := Result + 'MISC???';
      end;

    $01: { LOOKUP }
      begin
        Dd := mode and 3;  { destination D register from IR[10:9] }
        case opr and $FF of
          $E0: mnem:='SHL';    $E2: mnem:='SHR';    $E4: mnem:='ASR';
          $E6: mnem:='ROL';    $E8: mnem:='ROR';    $EA: mnem:='SWAPB';
          $EC: mnem:='HIGH';   $EE: mnem:='LOW';
          $F0: mnem:='SHR4';   $F2: mnem:='SHL4';   $F4: mnem:='ASR4';
          $F6: mnem:='ASR8';   $F8: mnem:='MULB';   $FA: mnem:='RECIP';
        else   mnem:=Format('LOOKUP#$%2.2X',[opr and $FF]);
        end;
        Result := Result + Format('%s %s', [mnem, DnName[Dd]]);
      end;

    $02: { INC/DEC }
      begin
        Xs := (opr shr 5) and 3;
        if mode = 0 then Result := Result + Format('INC %s',[XYName[Xs]])
        else             Result := Result + Format('DEC %s',[XYName[Xs]]);
      end;

    $03: { LEA }
      begin
        { dst XY = IR[8:7]=(opr shr 7)&3; src XY = IR[6:5]=(opr shr 5)&3 }
        { D reg for indexed = IR[4:3]=(opr shr 3)&3; imm5 = IR[4:0]=opr&$1F }
        Dd := (opr shr 7) and 3; Xs := (opr shr 5) and 3;
        case mode of
          0: if (opr and $1F) = 0 then
               Result := Result + Format('LEA %s, [%s]',    [XYName[Dd],XYName[Xs]])
             else
               Result := Result + Format('LEA %s, [%s+D%d]',[XYName[Dd],XYName[Xs],(opr shr 3) and 3]);
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LEA %s, [PC+$%4.4X]',[XYName[Dd],imm]); end;
          2: Result := Result + Format('LEA %s, [%s+#%d]',  [XYName[Dd],XYName[Xs],opr and $1F]);
          3: Result := Result + Format('LEA %s, [%s]',      [XYName[Dd],XYName[Xs]]);
        end;
      end;

    $04: { Scc }
      begin
        Dd:=(opr shr 1) and $0F; cond:=(opr shr 5) and 7;
        Result := Result + Format('S%s %s',[CcName[cond],Rf4Name(Dd)]);
      end;

    $05: { MOVE / SWAP }
      begin
        case mode of
          0: begin { MOVE dst(4bit), src(4bit) — src at bits 4:1 (IR bit 0 always 0) }
               rf4 := (opr shr 5) and $0F;
               li  := (opr shr 1) and $0F;
               Result := Result + Format('MOVE %s, %s',[Rf4Name(rf4), Rf4Name(li)]);
             end;
          1: begin { MOVE dst(4bit), src(4bit) }
               rf4 := (opr shr 5) and $0F;
               li  := (opr shr 1) and $0F;
               Result := Result + Format('MOVE %s, %s',[Rf4Name(rf4), Rf4Name(li)]);
             end;
          2,3: begin { SWAP reg, reg }
               rf4 := (opr shr 5) and $0F;
               li  := (opr shr 1) and $0F;
               Result := Result + Format('SWAP %s, %s',[Rf4Name(rf4), Rf4Name(li)]);
             end;
        end;
      end;

    $06: { PUSH }
    $06: { PUSH }
      begin
        Xs := (opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('PUSH %s, %s',[Rf4Name((opr shr 5) and $0F),XYName[Xs]]);
          1: Result := Result + Format('PUSH D-grp, %s',[XYName[Xs]]);
          2: Result := Result + Format('PUSH %s, %s',[XYName[(opr shr 5) and 3],XYName[Xs]]);
          3: Result := Result + Format('PUSH %s, %s',[Rf4Name((opr shr 5) and $0F),XYName[Xs]]);
        end;
      end;

    $07: { POP }
      begin
        Xs := (opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('POP %s, %s',[Rf4Name((opr shr 5) and $0F),XYName[Xs]]);
          1: Result := Result + Format('POP D-grp, %s',[XYName[Xs]]);
          2: Result := Result + Format('POP %s, %s',[XYName[(opr shr 5) and 3],XYName[Xs]]);
          3: Result := Result + Format('POPD %s',[XYName[Xs]]);
        end;
      end;

    $08,$09,$0A,$0B,$0C,$0D,$0E,$10: { ALU except NOT + CMP }
      begin
        Dd:=(opr shr 5) and $0F; Ds:=(opr shr 1) and $0F; li:=op-$08;
        Xs:=(opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('%s %s, %s',      [AluName[li],Rf4Name(Dd),Rf4Name(Ds)]);
          1: Result := Result + Format('%s %s, [%s]',    [AluName[li],Rf4Name(Dd),XYName[Xs]]);
          2: Result := Result + Format('%s %s, #%d',     [AluName[li],Rf4Name((opr shr 5) and $0F),opr and $1F]);
          3: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('%s %s, #$%4.4X',[AluName[li],Rf4Name((opr shr 5) and $0F),imm]); end;
        end;
      end;

    $0F: { NOT - special handling for correct operand routing }
      begin
        Dd:=(opr shr 5) and $0F; Ds:=(opr shr 1) and $0F;
        Xs:=(opr shr 1) and 3;
        case mode of
          0: Result := Result + Format('NOT %s, %s',      [Rf4Name(Dd),Rf4Name(Ds)]);      { NOT dest, src }
          1: Result := Result + Format('NOT %s, [%s]',    [Rf4Name(Dd),XYName[Xs]]);       { NOT dest, [XY] }
          2: Result := Result + Format('NOT %s',          [Rf4Name(Dd)]);                  { NOT dest (in-place) }
          3: begin imm:=MemReadWord(addr+2); BytesUsed:=4;                                  { NOT dest, #imm16 }
               Result := Result + Format('NOT %s, #$%4.4X',[Rf4Name(Dd),imm]); end;
        end;
      end;

    $11: { Bcc }
      begin
        cond := (opr shr 5) and 7;
        case mode of
          0: begin { short conditional }
               off := opr and $1F;
               Result := Result + Format('B%s +%d',[CcName[cond],off]);
             end;
          1: begin { long conditional }
               imm := MemReadWord(addr+2); BytesUsed := 4; off := SmallInt(imm);
               Result := Result + Format('B%s $%6.6X',
                 [CcName[cond], TAddr(Integer(addr+4)+off) and ADDR_MASK]);
             end;
          2: begin { BRA short }
               off := opr and $1F;
               Result := Result + Format('BRA +%d',[off]);
             end;
          3: begin { BRA long }
               imm := MemReadWord(addr+2); BytesUsed := 4; off := SmallInt(imm);
               Result := Result + Format('BRA $%6.6X',
                 [TAddr(Integer(addr+4)+off) and ADDR_MASK]);
             end;
        end;
      end;

    $12: { JMP }
      case mode of
        0: begin imm:=MemReadWord(addr+2); BytesUsed:=4; bank:=opr and $FF;
             Result := Result + Format('JMP24 $%2.2X%4.4X',[bank,imm]); end;
        1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('JMP16 $%4.4X',[imm]); end;
        2: Result := Result + Format('JMPT %s, %s',
             [XYName[(opr shr 5) and 3], DnName[(opr shr 7) and 3]]);
        3: Result := Result + Format('JMPXY %s',[XYName[(opr shr 5) and 3]]);
      end;

    $13: { CALL }
      case mode of
        0: begin imm:=MemReadWord(addr+2); BytesUsed:=4; bank:=opr and $FF;
             Result := Result + Format('CALL24 $%2.2X%4.4X',[bank,imm]); end;
        1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('CALL16 $%4.4X',[imm]); end;
        2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('CALLR %+d',[SmallInt(imm)]); end;
        3: Result := Result + Format('CALLXY %s',[XYName[(opr shr 5) and 3]]);
      end;

    $14,$15: { LOADD, LOADB -- mode 1 = [XYn+Dn] }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        if op = $14 then mnem := 'LOADD' else mnem := 'LOADB';
        case mode of
          0: Result := Result + Format('%s %s, [%s]',     [mnem,DnName[Dd],XYName[Xs]]);
          1: Result := Result + Format('%s %s, [%s+D%d]', [mnem,DnName[Dd],XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('%s %s, [PC+$%4.4X]',[mnem,DnName[Dd],imm]); end;
          3: Result := Result + Format('%s %s, [%s+#%d]', [mnem,DnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $16: { LOADX -- mode 1 = LOADI Xn, #imm16 }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('LOADX %s, [%s]',      [XnName[Dd],XYName[Xs]]);
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADI %s, #$%4.4X', [XnName[Dd],imm]); end;
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADX %s, [PC+$%4.4X]',[XnName[Dd],imm]); end;
          3: Result := Result + Format('LOADX %s, [%s+#%d]',  [XnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $17: { LOADY -- mode 1 = LOADI Yn, #imm8 }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('LOADY Y%d, [%s]',     [Dd,XYName[Xs]]);
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADI Y%d, #$%2.2X',[Dd,imm and $FF]); end;
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADY Y%d, [PC+$%4.4X]',[Dd,imm]); end;
          3: Result := Result + Format('LOADY Y%d, [%s+#%d]', [Dd,XYName[Xs],opr and $1F]);
        end;
      end;

    $18: { LOADI }
      begin
        { 4-bit reg field at bits[8:5]: D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11,
          ORDB=12, SR=13, PCH=14, PCL=15 }
        rf4 := (opr shr 5) and $0F;
        regname := Rf4Name(rf4);
        case mode of
          0: begin  { IMM5 }
               { Pretty-print SEC/CLC aliases as hints after the LOADI form }
               if (rf4 = 13) and ((opr and $1F) = 1) then
                 Result := Result + 'LOADI SR, #$01 (SEC)'
               else if (rf4 = 13) and ((opr and $1F) = 0) then
                 Result := Result + 'LOADI SR, #$00 (CLC)'
               else
                 Result := Result + Format('LOADI %s, #%d',[regname, opr and $1F]);
             end;
          1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('LOADI %s, #$%4.4X',[regname, imm]); end;
          2: Result := Result + Format('LOADXY %s, [%s]',
               [XYName[(opr shr 7) and 3],   { dest: bits[8:7] }
                XYName[(opr shr 5) and 3]]);  { src:  bits[6:5], 1 word total }
          3: begin imm := MemReadWord(addr+2); BytesUsed := 4;
               if (opr shr 3) and 1 = 1 then
                 Result := Result + Format('LOADPB %s, Y%d, [#$%4.4X]',
                   [Rf4Name(rf4), (opr shr 1) and 3, imm])
               else
                 Result := Result + Format('LOADP %s, Y%d, [#$%4.4X]',
                   [Rf4Name(rf4), (opr shr 1) and 3, imm]);
             end;
        end;
      end;

    $19,$1A: { STORED, STOREB -- mode 1 = [XYn+Dn] }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        if op = $19 then mnem := 'STORED' else mnem := 'STOREB';
        case mode of
          0: Result := Result + Format('%s %s, [%s]',     [mnem,DnName[Dd],XYName[Xs]]);
          1: Result := Result + Format('%s %s, [%s+D%d]', [mnem,DnName[Dd],XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('%s %s, [PC+$%4.4X]',[mnem,DnName[Dd],imm]); end;
          3: Result := Result + Format('%s %s, [%s+#%d]', [mnem,DnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $1B: { STOREX }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('STOREX %s, [%s]',     [XnName[Dd],XYName[Xs]]);
          1: Result := Result + Format('STOREX %s, [%s+D%d]', [XnName[Dd],XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('STOREX %s, [PC+$%4.4X]',[XnName[Dd],imm]); end;
          3: Result := Result + Format('STOREX %s, [%s+#%d]', [XnName[Dd],XYName[Xs],opr and $1F]);
        end;
      end;

    $1C: { STOREY }
      begin
        Dd:=(opr shr 7) and 3; Xs:=(opr shr 5) and 3;
        case mode of
          0: Result := Result + Format('STOREY Y%d, [%s]',     [Dd,XYName[Xs]]);
          1: Result := Result + Format('STOREY Y%d, [%s+D%d]', [Dd,XYName[Xs],(opr shr 3) and 3]);
          2: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
               Result := Result + Format('STOREY Y%d, [PC+$%4.4X]',[Dd,imm]); end;
          3: Result := Result + Format('STOREY Y%d, [%s+#%d]', [Dd,XYName[Xs],opr and $1F]);
        end;
      end;

    $1D: { STOREI }
      case mode of
        0: Result := Result + Format('STOREI #%d, [%s]',
             [opr and $1F, XYName[(opr shr 5) and 3]]);
        1: begin imm:=MemReadWord(addr+2); BytesUsed:=4;
             Result := Result + Format('STOREI #$%4.4X, [%s]',
               [imm,XYName[(opr shr 5) and 3]]); end;
        2: Result := Result + Format('STOREXY [%s], %s',
             [XYName[(opr shr 7) and 3],XYName[(opr shr 5) and 3]]);
        3: begin imm := MemReadWord(addr+2); BytesUsed := 4;
             if (opr shr 3) and 1 = 1 then
               Result := Result + Format('STOREPB %s, Y%d, [#$%4.4X]',
                 [Rf4Name((opr shr 5) and $0F), (opr shr 1) and 3, imm])
             else
               Result := Result + Format('STOREP %s, Y%d, [#$%4.4X]',
                 [Rf4Name((opr shr 5) and $0F), (opr shr 1) and 3, imm]);
           end;
      end;

    $1E: { TRAP / RET }
      if mode = 0 then
        Result := Result + Format('TRAP #%d',[(opr and $FF) shr 1])
      else if mode = 3 then
      begin
        if opr and $1F = 0 then Result := Result + 'RET'
        else Result := Result + Format('RET #%dw',[opr and $1F]);
      end else
        Result := Result + 'TRAP/RET???';

    $1F: { INT }
      case mode of
        0: Result := Result + 'DINT';
        1: Result := Result + 'EINT';
        2: Result := Result + 'RTI';
        3: Result := Result + 'INT';
      end;

  else
    Result := Result + Format('??? op=$%2.2X mode=%d',[op,mode]);
  end;
end;

function FormatMem(addr: TAddr; words: Word): string;
var i: Integer; a: TAddr;
begin
  Result := '';
  for i := 0 to words-1 do
  begin
    a := (addr + TAddr(i*2)) and ADDR_MASK;
    if i mod 8 = 0 then
    begin
      if i > 0 then Result := Result + LineEnding;
      Result := Result + Format('$%6.6X:',[a]);
    end;
    Result := Result + Format(' %4.4X',[MemReadWord(a)]);
  end;
end;

end.
