{
  K16_PseudoCommon.pas — K16 Assembler Pseudo-Instruction Common Types

  Shared definitions for the pseudo-instruction expansion units
  (K16_PseudoBranch, K16_PseudoShift). Pure data types; no parser or
  encoder coupling — these units must be unit-testable in isolation.

  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU

  License: MIT
}
unit K16_PseudoCommon;

{$mode Delphi}

interface

uses
  SysUtils;

type
  // One native instruction emitted by a pseudo expansion. Text-level —
  // the assembler re-parses each entry through K16_Parser, so the
  // expansion units don't depend on TInstructionRecord internals.
  //
  // SyntheticLabel: if non-empty, this label is defined at the address
  // immediately preceding this instruction (i.e. attached as a label to
  // the NEXT emitted record).  For BHI, the synthetic label is attached
  // to a sentinel entry whose Mnemonic field is empty — see
  // K16_PseudoBranch.
  TPseudoInstruction = record
    Mnemonic:        string;     // e.g. 'SHL', 'BEQ', 'LOADI'
    Operands:        string;     // e.g. 'D0', '.__bhi_42', 'D2, #0'
    SyntheticLabel:  string;     // optional — label defined at THIS address
    Comment:         string;     // optional — for listing decoration
  end;

  TInstructionSequence = array of TPseudoInstruction;

  TShiftDirection = (sdSHL, sdSHR, sdASR);

  // Counter for synthetic label generation.  Lives on the assembler
  // instance (one per file) so labels are stable and globally unique.
  TPseudoLabelCounter = class
  private
    FNext: Integer;
  public
    constructor Create;
    function NewBHILabel: string;
  end;

// Helper: build a TPseudoInstruction with no label or comment.
function PI(const Mnemonic, Operands: string): TPseudoInstruction; overload;

// Helper: build a TPseudoInstruction with a synthetic label attached.
// Used for the BHI skip-target sentinel — Mnemonic is left empty so the
// caller can tell it's a label-only entry, not a real instruction.
function PILabel(const SyntheticLabel: string): TPseudoInstruction;

implementation

function PI(const Mnemonic, Operands: string): TPseudoInstruction;
begin
  Result.Mnemonic       := Mnemonic;
  Result.Operands       := Operands;
  Result.SyntheticLabel := '';
  Result.Comment        := '';
end;

function PILabel(const SyntheticLabel: string): TPseudoInstruction;
begin
  Result.Mnemonic       := '';
  Result.Operands       := '';
  Result.SyntheticLabel := SyntheticLabel;
  Result.Comment        := '';
end;

{ TPseudoLabelCounter }

constructor TPseudoLabelCounter.Create;
begin
  inherited;
  FNext := 0;
end;

function TPseudoLabelCounter.NewBHILabel: string;
begin
  Result := Format('.__bhi_%d', [FNext]);
  Inc(FNext);
end;

end.
