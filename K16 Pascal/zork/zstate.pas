{ ---------------------------------------------------------------------------
  zstate.pas -- Z-machine stacks and call frames             K16 Pascal, Part 27

  Include AFTER zdis and BEFORE zsave and zexec.

  Declarations only. Every line here was in zexec.pas up to Part 26 and moved
  out unchanged in Part 27, with one addition (ZFArgs).

  ---- Why this file exists -------------------------------------------------

  Ordering, and nothing else. This compiler is single pass, so a routine must
  be declared before it is called. zsave needs the frame arrays; zexec needs
  to call zsave from ZExec0OP. That forces zsave to sit between the state and
  zexec, and the state therefore has to come out of zexec into its own file.

  The alternative -- a forward declaration, or a nested include -- buys
  nothing and hides the dependency. This way the include order in zork.pas
  reads as the dependency graph.

  ---- Why the call stack is an explicit array ------------------------------

  This compiler allocates locals STATICALLY -- they appear as l_Routine_name
  in the GLOBALS region -- so a recursive Pascal routine overwrites its own
  caller's locals. The Z-machine's call stack therefore cannot be the Pascal
  call stack, and ZFrames below is not a design preference, it is forced.
  Part 27 collects on the parenthesis Part 26 left here: `save' has to
  serialise it, and an explicit array is trivial to walk.
  --------------------------------------------------------------------------- }

const
  { Inclusive upper bounds -- bounds must be constant identifiers. }
  ZS_TOP    = 1023;       { Z-machine evaluation stack, words }
  ZF_TOP    = 63;         { call frames }
  ZL_COUNT  = 15;         { locals per routine, v3 maximum }
  ZLOC_TOP  = 959;        { (ZF_TOP + 1) * ZL_COUNT - 1, written out }

  ZRETVAR_NONE = $0100;   { no store variable; outside the 0..255 range }

var
  ZStack   : array[0..ZS_TOP] of Word;
  ZSP      : Word;                        { next free slot }

  ZFPCOfs  : array[0..ZF_TOP] of Word;    { return cursor }
  ZFPCPage : array[0..ZF_TOP] of Word;
  ZFFloor  : array[0..ZF_TOP] of Word;    { ZSP on entry }
  ZFNLoc   : array[0..ZF_TOP] of Word;
  ZFRetVar : array[0..ZF_TOP] of Word;

  { Number of arguments the call supplied. Recorded solely so `save' can
    write Quetzal's `arguments supplied' byte (s4.3.4) honestly rather than
    zero-filling it. Nothing in a v3 interpreter reads it back -- the opcode
    that needs it, check_arg_count, is v5 -- but a save file is a public
    artifact and another interpreter may one day care. }
  ZFArgs   : array[0..ZF_TOP] of Word;

  ZLocals  : array[0..ZLOC_TOP] of Word;  { frame * ZL_COUNT + n }
  ZFP      : Word;                        { current frame index }

  { ZFP * ZL_COUNT, maintained incrementally rather than recomputed.

    ZLIdx used to do the multiply on every local variable read AND write --
    the most frequent operation in the interpreter, and one most Z-opcodes
    perform at least once. K16 has no 16x16 multiply in hardware; the ROM ALU
    cannot table a 32-bit result, so it is a shift-add routine of roughly
    sixteen iterations.

    ZFP only ever moves by one, in ZDoCall and ZDoReturn, so the product can
    be carried alongside it for an add and a subtract. Every assignment to
    ZFP must have a matching adjustment here -- there are exactly four, in
    ZExecInit, ZDoCall, ZDoReturn and ZQCommitStks, plus the reset in
    ZQRestart.

    The one place it is still computed the honest way is ZQCommitStks, which
    rebuilds ZFP wholesale from a save file and runs once per restore. }
  ZFBase   : Word;
