program K16EmuIDE;
{
  K16 Emulator IDE -- Lazarus LCL GUI Application
  Part of the K16 homebrew CPU project.
}
{$mode Delphi}
{$H+}
{$IFDEF WINDOWS}
  {$APPTYPE GUI}
{$ENDIF}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Interfaces,
  Forms,
  frm_main;

begin
  RequireDerivedFormResource := True;   Application.Title:='K16 Emulator IDE';

  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
