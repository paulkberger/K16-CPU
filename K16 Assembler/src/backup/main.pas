unit Main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ComCtrls,
  StdCtrls, ExtCtrls, EditBtn, ActnList, StdActns,
  IniFiles, SynEdit, SynEditTypes,
  K16_Assembler,
  K16_Export,
  K16_SynEditHighlighter,
  K16_SynListingHighlighter;


type

  { TFormMain }

  TFormMain = class(TForm)
    ActionGenerateCOM: TAction;
    ActionGenerateHEX: TAction;
    ActionFileSave: TAction;
    ActionFileOpen: TAction;
    ActionFileNew: TAction;
    ActionGenerateROMs: TAction;
    ActionAssemble: TAction;
    ActionList1: TActionList;
    CheckBoxAddLookups: TCheckBox;
    DirectoryEdit: TDirectoryEdit;
    EditCopy1: TEditCopy;
    EditCut1: TEditCut;
    EditDelete1: TEditDelete;
    EditPaste1: TEditPaste;
    EditSelectAll1: TEditSelectAll;
    EditUndo1: TEditUndo;
    FileNameEditROMdisk: TFileNameEdit;
    ImageList1: TImageList;
    LabelOutputDir: TLabel;
    LabelROMdisk: TLabel;
    MainMenu1: TMainMenu;
    MemoOutput: TMemo;
    MenuItem1: TMenuItem;
    MenuItemAssGenerateHEX: TMenuItem;
    MenuItemEditPaste: TMenuItem;
    MenuItemEditCut: TMenuItem;
    MenuItemEditDelete: TMenuItem;
    MenuItemEditSelectAll: TMenuItem;
    MenuItemEditUndo: TMenuItem;
    MenuItemEdit: TMenuItem;
    MenuItemEditCopy: TMenuItem;
    MenuItemFile: TMenuItem;
    MenuItemFileNew: TMenuItem;
    MenuItemFileOpen: TMenuItem;
    MenuItemFileSave: TMenuItem;
    MenuItemFileSaveAs: TMenuItem;
    MenuItemFileExit: TMenuItem;
    MenuItemAssembler: TMenuItem;
    MenuItemAssAssemble: TMenuItem;
    MenuItemAssGenerateROMs: TMenuItem;
    OpenDialog: TOpenDialog;
    PageControl: TPageControl;
    SaveDialog: TSaveDialog;
    Separator1: TMenuItem;
    Separator3: TMenuItem;
    Splitter1: TSplitter;
    StatusBar1: TStatusBar;
    seEditSource: TSynEdit;
    seSourceListing: TSynEdit;
    TabSheetSource: TTabSheet;
    TabSheetListing: TTabSheet;
    TabSheetSettings: TTabSheet;
    ToolBar1: TToolBar;
    ToolButton1: TToolButton;
    ToolButton10: TToolButton;
    ToolButton2: TToolButton;
    ToolButton3: TToolButton;
    ToolButton4: TToolButton;
    ToolButton5: TToolButton;
    ToolButton6: TToolButton;
    ToolButton7: TToolButton;
    ToolButton8: TToolButton;
    procedure ActionFileNewExecute(Sender: TObject);
    procedure ActionGenerateCOMExecute(Sender: TObject);
    procedure ActionGenerateHEXExecute(Sender: TObject);
    procedure ActionAssembleExecute(Sender: TObject);
    procedure ActionFileOpenExecute(Sender: TObject);
    procedure ActionFileSaveExecute(Sender: TObject);
    procedure ActionGenerateROMsExecute(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure PageControlChange(Sender: TObject);
    procedure TabSheetSettingsExit(Sender: TObject);
  private
  var
     K16Assembler: TK16Assembler;
     FileName: string;
     Settings: TMemIniFile;
     LoadFolder: string;        // remembered .com output folder (= EMU load/ dir)
     procedure seEditSourceStatusChange(Sender: TObject; Changes: TSynStatusChanges);
     procedure seSourceListingStatusChange(Sender: TObject; Changes: TSynStatusChanges);
     procedure UpdateCaption( ACaption : String );
     procedure UpdateStatusBarText;
     procedure OnAssemblerMessage(const Msg: string);
  public

  end;

var
  FormMain: TFormMain;

implementation

{$R *.lfm}

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
begin
     WindowState := wsMaximized;
     PageControl.ActivePage := TabSheetSource;
     StatusBar1.Panels[0].Text := '';
     UpdateCaption('');

     Screen.MenuFont.Name := 'Segoe UI';
     //Screen.MenuFont.Size := 10;

     seEditSource.Highlighter    := TSynK16Syn.Create(Self);
     seEditSource.OnStatusChange := @seEditSourceStatusChange;
     seSourceListing.Highlighter := TSynK16ListingSyn.Create(Self);
     seSourceListing.OnStatusChange:= @seSourceListingStatusChange;
     UpdateStatusBarText;

     Settings := TMemIniFile.Create(ChangeFileExt(ParamStr(0), '.ini'));
     DirectoryEdit.Directory    := Settings.ReadString('OutputPath','Path', '' );
     CheckBoxAddLookups.Checked := Settings.ReadBool('Lookups','Add', true);
     LoadFolder                 := Settings.ReadString('Inject','LoadFolder', '');

     ActionGenerateROMs.Enabled := False;
     ActionGenerateHEX.Enabled  := False;
     ActionGenerateCOM.Enabled  := False;
end;

procedure TFormMain.PageControlChange(Sender: TObject);
begin
     UpdateStatusBarText;
end;

procedure TFormMain.UpdateStatusBarText;
var s : string;
begin
  s := '';

  if PageControl.ActivePage = TabSheetSource then
   s := Format('  %d:  %d', [seEditSource.CaretY, seEditSource.CaretX])
  else
  if PageControl.ActivePage = TabSheetListing then
    s := Format('  %d:  %d', [seSourceListing.CaretY, seSourceListing.CaretX]);

  StatusBar1.Panels[0].Text := s;
end;

procedure TFormMain.TabSheetSettingsExit(Sender: TObject);
var path: string;
begin
  Path := Trim( DirectoryEdit.Text );

  if (Path <> '') and (Path[Length(Path)] <> '\') then
    Path := Path + '\';

  DirectoryEdit.Directory := path;
  Settings.WriteString('OutputPath','Path', Path );
  Settings.WriteBool('Lookups','Add', CheckBoxAddLookups.Checked )

end;


procedure TFormMain.UpdateCaption(ACaption: string);
begin
  self.Caption := 'K16 Assembler';

  if ACaption <> '' then
    self.Caption := Self.Caption + ' - ' + ACaption;

end;


procedure TFormMain.seEditSourceStatusChange(Sender: TObject; Changes: TSynStatusChanges);
begin
  if [scCaretX, scCaretY] * Changes <> [] then
    UpdateStatusBarText;

  if scModified in Changes then
  begin
    ActionGenerateROMs.Enabled := False;
    ActionGenerateHEX.Enabled  := False;
    ActionGenerateCOM.Enabled  := False;
  end;
end;

procedure TFormMain.seSourceListingStatusChange(Sender: TObject; Changes: TSynStatusChanges);
begin
  if [scCaretX, scCaretY] * Changes <> [] then
    UpdateStatusBarText;
end;

procedure TFormMain.ActionAssembleExecute(Sender: TObject);
begin
     MemoOutput.Lines.Clear;
     MemoOutput.Lines.Add('Messages:' );
     MemoOutput.Update;

     seSourceListing.Clear;

     //Start Fresh
     FreeAndNil( K16Assembler );
     K16Assembler := TK16Assembler.Create;
     K16Assembler.OnMessage := @OnAssemblerMessage;

     try

       K16Assembler.SourceFileName := FileName;

       if K16Assembler.AssembleText( seEditSource.Text) then
       begin
         MemoOutput.Lines.Add('' );
         MemoOutput.Lines.Add('Assembly successful!' );

         ActionGenerateROMs.Enabled := True;
         ActionGenerateHEX.Enabled  := True;
         ActionGenerateCOM.Enabled  := True;

         if K16Assembler.HasWarnings then
         begin
           MemoOutput.Lines.Add('' );
           MemoOutput.Lines.Add('Warnings:');
           MemoOutput.Lines.AddStrings( K16Assembler.WarningList );
         end;
         //Assembler.GenerateIntelHex('program.hex');
         //Assembler.GenerateBinary('program.bin');

         seSourceListing.Text := K16Assembler.GenerateListingText;
         PageControl.ActivePage := TabSheetListing;
         UpdateStatusBarText;
         //Assembler.GenerateListing('program.lst');

       end else
       begin
         ActionGenerateROMs.Enabled := False;
         ActionGenerateHEX.Enabled  := False;
         ActionGenerateCOM.Enabled  := False;

         MemoOutput.Lines.Add('' );
         MemoOutput.Lines.Add('Errors:');
         MemoOutput.Lines.AddStrings( K16Assembler.ErrorList );
       end;
     finally
       //Assembler.Free;
     end;

end;

procedure TFormMain.ActionGenerateHEXExecute(Sender: TObject);
var s : string;
begin
  SaveDialog.Filter      := 'Intel HEX (*.hex)|*.hex|All files (*.*)|*.*';
  SaveDialog.FilterIndex := 1;
  SaveDialog.DefaultExt  := 'hex';
  SaveDialog.Options     := SaveDialog.Options + [ofOverwritePrompt];
  if FileName <> '' then
    SaveDialog.FileName := ChangeFileExt(FileName, '.hex')
  else
    SaveDialog.FileName := '';
  if SaveDialog.Execute then
  begin
    s := GenerateIntelHex(K16Assembler, SaveDialog.FileName);
    MemoOutput.Lines.Add( s );
  end;
end;

procedure TFormMain.ActionFileNewExecute(Sender: TObject);
begin
  if seEditSource.Modified then
  begin
    case MessageDlg('The current file has been modified. Save changes?',
                    mtConfirmation, [mbYes, mbNo, mbCancel], 0) of
      mrYes:    begin
                  ActionFileSaveExecute(Sender);
                  if seEditSource.Modified then  // user cancelled save
                    Exit;
                end;
      mrCancel: Exit;
    end;
  end;

  seEditSource.Clear;
  seEditSource.Modified := False;
  seSourceListing.Clear;
  MemoOutput.Lines.Clear;

  FreeAndNil( K16Assembler );
  ActionGenerateROMs.Enabled := False;
  ActionGenerateHEX.Enabled  := False;
  ActionGenerateCOM.Enabled  := False;

  FileName := '';
  UpdateCaption('');
  PageControl.ActivePage := TabSheetSource;
end;

procedure TFormMain.ActionGenerateCOMExecute(Sender: TObject);
// Save a .COM next to the EMU's load/ folder so kosh can pick it up
// with `load <name>`. The folder is remembered in the INI under
// [Inject] LoadFolder — first save asks for the path; subsequent saves
// default there.
var
  s             : string;
  defaultName   : string;
  chosenFolder  : string;
begin
  SaveDialog.Filter      := 'k/OS executable (*.com)|*.com|All files (*.*)|*.*';
  SaveDialog.FilterIndex := 1;
  SaveDialog.DefaultExt  := 'com';
  SaveDialog.Options     := SaveDialog.Options + [ofOverwritePrompt];

  // Default filename: <sourcebasename>.com if a source file is open.
  if FileName <> '' then
    defaultName := ChangeFileExt(ExtractFileName(FileName), '.com')
  else
    defaultName := '';

  // Default directory: the remembered LoadFolder if set; falls back to
  // the dialog's last-used directory (which Windows preserves per-ext).
  if (LoadFolder <> '') and DirectoryExists(LoadFolder) then
  begin
    SaveDialog.InitialDir := LoadFolder;
    if defaultName <> '' then
      SaveDialog.FileName := IncludeTrailingPathDelimiter(LoadFolder) + defaultName
    else
      SaveDialog.FileName := '';
  end
  else
  begin
    SaveDialog.InitialDir := '';
    SaveDialog.FileName   := defaultName;
  end;

  if SaveDialog.Execute then
  begin
    s := GenerateCom(K16Assembler, SaveDialog.FileName);
    MemoOutput.Lines.Add( s );
    // On success, remember the folder for next time. Non-sticky — if
    // the user navigates elsewhere, the new folder becomes the default.
    if not s.StartsWith('Error') then
    begin
      chosenFolder := ExcludeTrailingPathDelimiter(
                        ExtractFilePath(SaveDialog.FileName));
      if (chosenFolder <> '') and (chosenFolder <> LoadFolder) then
      begin
        LoadFolder := chosenFolder;
        Settings.WriteString('Inject', 'LoadFolder', LoadFolder);
      end;
    end;
  end;
end;


procedure TFormMain.OnAssemblerMessage(const Msg: string);
begin
  MemoOutput.Lines.Add(Msg);
end;

procedure TFormMain.ActionFileOpenExecute(Sender: TObject);
begin
  OpenDialog.Filter :=
    'K16 Assembly files (*.asm;*.K16)|*.asm;*.K16|' +
    'Kiama K16 files (*.K16)|*.K16|' +
    'Assembly files (*.asm)|*.asm|' +
    'Text files (*.txt)|*.txt|' +
    'All files (*.*)|*.*';
  OpenDialog.FilterIndex := 1;

  if OpenDialog.Execute then
  begin
    if FileExists(OpenDialog.FileName) then
    begin
      seEditSource.Lines.LoadFromFile(OpenDialog.FileName);
      ActionGenerateROMs.Enabled := False;
      ActionGenerateHEX.Enabled  := False;
      ActionGenerateCOM.Enabled  := False;
      FileName := OpenDialog.FileName;
      UpdateCaption( FileName );
      PageControl.ActivePage := TabSheetSource;
    end
    else
      raise Exception.Create('File does not exist: ' + OpenDialog.FileName);
  end;

end;

procedure TFormMain.ActionFileSaveExecute(Sender: TObject);
begin
  SaveDialog.Filter :=
    'K16 Assembly files (*.asm;*.K16)|*.asm;*.K16|' +
    'Kiama K16 files (*.K16)|*.K16|' +
    'Assembly files (*.asm)|*.asm|' +
    'Text files (*.txt)|*.txt|' +
    'All files (*.*)|*.*';
  SaveDialog.FilterIndex := 1;
  SaveDialog.DefaultExt := 'asm';
  SaveDialog.Options := SaveDialog.Options + [ofOverwritePrompt];
  if SaveDialog.Execute then
  begin
    seEditSource.Lines.SaveToFile(SaveDialog.FileName);
    FileName := SaveDialog.FileName;
    UpdateCaption( FileName );
  end;
end;

procedure TFormMain.ActionGenerateROMsExecute(Sender: TObject);
var s : string;
begin
  if K16Assembler = nil then
  begin
    MemoOutput.Lines.Add('Cannot generate ROMs: assemble the source first.');
    Exit;
  end;
  s := GenerateROMs( K16Assembler, DirectoryEdit.Text, CheckBoxAddLookups.Checked );
  MemoOutput.Lines.Add( s );
end;


procedure TFormMain.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  FreeAndNil( K16Assembler );

  Settings.UpdateFile;  // writes only if modified
  Settings.Free;
end;

end.
