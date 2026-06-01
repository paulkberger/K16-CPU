{
  K16_PseudoBranch.pas — K16 Assembler Branch Pseudo-Instructions

  Implements BHI (Branch if Higher, unsigned strict) and BLS (Branch if
  Lower or Same, unsigned) as pseudo-instructions.  Both expand to a
  short sequence of native branches that test the C and Z flags set by
  a preceding CMP.

    BHI target   =>  BEQ .__bhi_N       ; skip on equal
                     BHS target         ; branch on >= (and not equal => >)
                     .__bhi_N:

    BLS target   =>  BEQ target         ; equal => take branch
                     BLO target         ; below => take branch

  Pure functions: no parser/encoder coupling.  The assembler is
  responsible for re-parsing the returned text into TInstructionRecord
  and emitting the synthetic label at the right PC.

  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU

  License: MIT
}
unit K16_PseudoBranch;

{$mode Delphi}

interface

uses
  SysUtils,
  K16_PseudoCommon;

type
  TBranchSizeHint = (bshAuto, bshShort, bshLong);

// ExpandBHI: branch if A > B unsigned (strict).
//
// Target: the user-supplied label (e.g. '.reject', 'MY_FUNC').
// SizeHint: bshAuto = let assembler decide; bshShort/bshLong force the
//   BHS to a specific size.  The synthetic BEQ is always 2 bytes
//   forward, always fits in short form.
// Counter: provides the synthetic label name (parent-scope-aware
//   qualification happens later in the assembler).
function ExpandBHI(const Target: string;
                   SizeHint: TBranchSizeHint;
                   Counter: TPseudoLabelCounter): TInstructionSequence;

// ExpandBLS: branch if A <= B unsigned.
//
// Both internal branches share Target — no synthetic label.  SizeHint
// applies to both BEQ and BLO uniformly (the assembler will use the
// hinted size for both; auto picks per-branch).
function ExpandBLS(const Target: string;
                   SizeHint: TBranchSizeHint): TInstructionSequence;

implementation

function ApplySizeSuffix(const Mnemonic: string; SizeHint: TBranchSizeHint): string;
begin
  case SizeHint of
    bshShort: Result := Mnemonic + '.S';
    bshLong:  Result := Mnemonic + '.L';
    else      Result := Mnemonic;   // bshAuto — let encoder pick
  end;
end;

function ExpandBHI(const Target: string;
                   SizeHint: TBranchSizeHint;
                   Counter: TPseudoLabelCounter): TInstructionSequence;
var
  SkipLabel: string;
begin
  Result := nil;
  if Counter = nil then
    raise Exception.Create('ExpandBHI: counter is nil');
  if Trim(Target) = '' then
    raise Exception.Create('ExpandBHI: empty target');

  SkipLabel := Counter.NewBHILabel;

  SetLength(Result, 3);

  // BEQ to skip label — always 2 bytes forward, always short.
  Result[0]         := PI('BEQ.S', SkipLabel);
  Result[0].Comment := 'BHI: skip if equal';

  // BHS to user target — size per hint (auto by default).
  Result[1]         := PI(ApplySizeSuffix('BHS', SizeHint), Target);
  Result[1].Comment := 'BHI: take if >=  (and not equal => >)';

  // Sentinel label entry — assembler attaches this label to whatever
  // comes next (i.e. defines it at the PC immediately after BHS).
  Result[2] := PILabel(SkipLabel);
end;

function ExpandBLS(const Target: string;
                   SizeHint: TBranchSizeHint): TInstructionSequence;
begin
  Result := nil;
  if Trim(Target) = '' then
    raise Exception.Create('ExpandBLS: empty target');

  SetLength(Result, 2);

  Result[0]         := PI(ApplySizeSuffix('BEQ', SizeHint), Target);
  Result[0].Comment := 'BLS: take on equal';

  Result[1]         := PI(ApplySizeSuffix('BLO', SizeHint), Target);
  Result[1].Comment := 'BLS: take on below';
end;

end.
