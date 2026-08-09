{
  k16_system.pas - K16 CPU Runtime Library stub for PASTA/80
  Minimal built-in definitions to satisfy the parser.
  Full implementations are in k16_rtl.asm.
}

{ ---- Heap ---- }

procedure InitHeap; external;
procedure GetMem(var P: Pointer; Size: Integer); external '__getmem';
procedure FreeMem(var P: Pointer; Size: Integer); external '__freemem';

{ ---- Console output ---- }

procedure __putc; external;
procedure __putn; external;
procedure __puts; external;
procedure __putf; external;
procedure __pute; external;
procedure __putn_fmt; external;
procedure __putc_fmt; external;
procedure __puts_fmt; external;
procedure __putf_fix; external;
procedure WriteLnCR; external;
procedure __newline; external;

{ ---- Console input ---- }

procedure __getc; external;
procedure __getn; external;
procedure __getr; external;
procedure __gets; external;
procedure __gete; external;

{ ---- String operations ---- }

procedure __loadstr; external;
procedure __storestr; external;
procedure __movestr; external;
procedure __mkstr; external;
procedure __rmstr; external;
procedure __loadfp; external;
procedure __storefp; external;
procedure __char2str; external;
procedure __strn; external;
procedure __strc; external;
procedure __strs; external;
procedure __strf; external;
procedure __stre; external;
procedure __strn1; external;
procedure __strc1; external;
procedure __strf2; external;
procedure __streq; external;
procedure __strlt; external;
procedure __strleq; external;

{ ---- Integer arithmetic ---- }

procedure __mul16; external;
procedure __sdiv16; external;
procedure __shl16; external;
procedure __shr16; external;
procedure __load16; external;
procedure __store16; external;
procedure __inc16; external;
procedure __dec16; external;

{ ---- Set operations ---- }

procedure __setmember; external;
procedure __setadd; external;
procedure __setsub; external;
procedure __setmul; external;
procedure __seteq; external;
procedure __setleq; external;
procedure __setgeq; external;

{ ---- Float operations ---- }

procedure __fpadd; external;
procedure __fpsub; external;
procedure __fpmul; external;
procedure __fpdiv; external;
procedure __fpmod; external;
procedure __fpneg; external;
procedure __flteq; external;
procedure __fltlt; external;
procedure __fltleq; external;
procedure __putf_exp; external;

{ ---- Stack check ---- }

procedure CheckStack; external;

{ ---- Standard string functions ---- }

procedure Delete(var S: String; Start, Count: Integer); external '__delete';
procedure Insert(S: String; var T: String; Start: Integer); external '__insert';
function  Copy(S: String; Start, Count: Integer): String; external '__copy';
{ Length(S) is now an inline magic builtin - no external declaration needed }
function  Pos(Needle, Haystack: String): Integer;         external '__pos';


end.
