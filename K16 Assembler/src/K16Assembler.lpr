program K16Assembler;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, lazcontrols, Main, K16_Assembler, K16_Encoder_ALU, K16_Encoder_Base,
  K16_Encoder_Branch, K16_Encoder_Call, K16_Encoder_Compare,
  K16_Encoder_ConditionalSet, K16_Encoder_Control, K16_Encoder_IncDec,
  K16_Encoder_Interrupt, K16_Encoder_Jump, K16_Encoder_LEA, K16_Encoder_Load,
  K16_Encoder_Lookup, K16_Encoder_Move, K16_Encoder_PushPop, K16_Encoder_Store,
  K16_Export, K16_Parser, K16_Encoder_TrapRet, K16_Encoder_Stream
  { you can add units after this };

{$R *.res}

begin
  RequireDerivedFormResource:=True;
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar:=True;
  {$POP}
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.

