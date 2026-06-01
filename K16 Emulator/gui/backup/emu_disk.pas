unit emu_disk;

{ K16 Disk Controller — host-file backend.

  Part 23 redesign (10 May 2026):
  --------------------------------
  The pool/catalogue layer is gone. The host directory `disk\` IS the
  catalogue. Persistent bay assignments live in the INI section [Disks]
  as plain `C=name.kos` entries:

    [Disks]
    DiskPath=disk
    LoadPath=load
    C=TEST.KOS
    D=USERDATA.KOS
    E=
    F=

  At boot the controller opens whichever named file is on each bay; bays
  with empty values stay empty. mount/unmount edit those entries directly
  and SaveDiskMounts persists.

  Three folders / paths:

    DiskFolder    : where .KOS files live (default 'disk\' next to .exe).
    LoadFolder    : where loadable host files live for the `load` command
                    (default 'load\' next to .exe).
    DiskMounts    : array[0..3] of string — filename per bay (or '').

  k/OS issues mount/unmount/list/create/delete via DSK_HOST_CMD; emu
  side updates the INI in real time.

  Part 25 r6 (11 May 2026): added HOST_CMD_FOPEN/FREAD/FCLOSE for the
  kosh `load` command — lets k/OS ingest host-side files (typically
  newly-assembled .COM files from the IDE) without unmounting the
  destination .KOS image. Streams via the existing DSK_BUF pointer
  rather than adding new MMIO registers.

  Drive-letter mapping is k/OS state, not emu state. This unit knows
  nothing about A:/B:/C:/etc — it speaks bays only.

  MMIO range: $DA0000..$DA001F. Sector size 512.
}

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, emu_types;

const
  // ---- MMIO map -----------------------------------------------------------
  DSK_BASE         = $DA0000;
  DSK_TOP          = $DA001F;

  // Sector-IO registers (unchanged)
  DSK_CMD          = $DA0000;   // W: sector command
  DSK_STATUS       = $DA0002;   // R: bit 0 busy (always 0 sync)
  DSK_DRIVE        = $DA0004;   // R/W: drive bay 0..3
  DSK_LBA_LO       = $DA0006;   // R/W: sector # bits 15..0
  DSK_LBA_HI       = $DA0008;   // R/W: sector # bits 23..16
  DSK_BUF_LO       = $DA000A;   // R/W: K16 buffer bits 15..0
  DSK_BUF_HI       = $DA000C;   // R/W: K16 buffer bits 23..16
  DSK_SECCOUNT     = $DA000E;   // R/W: sector count; drive size after IDENT
  DSK_RESULT       = $DA0010;   // R:   result of last command
  DSK_FLAGS        = $DA0012;   // R/W: bit0 present, bit1 RO, bit2 media-changed

  // Host-management register (Part 23 — replaces DSK_POOL_CMD).
  // Same address as the old DSK_POOL_CMD so the MMIO map is unchanged.
  DSK_HOST_CMD     = $DA0016;   // W: host management command
  // $DA0014/$DA0018/$DA001A formerly held DSK_POOL_SLOT / DSK_POOL_FLAGS /
  // DSK_POOL_COUNT. They now read as 0 and writes are silently ignored.

  // ---- Sector commands (unchanged) ----------------------------------------
  CMD_NONE         = $0000;
  CMD_READ         = $0001;     // SECCOUNT sectors at LBA → buffer
  CMD_WRITE        = $0002;     // buffer → SECCOUNT sectors at LBA
  CMD_IDENT        = $0003;     // SECCOUNT,FLAGS reflect selected DRIVE
  CMD_FLUSH        = $0004;     // sync (no-op for TFileStream)
  CMD_FORMAT       = $0005;     // zero-fill all sectors of DRIVE
  CMD_MEDIA        = $0006;     // refresh FLAGS, clear media-changed

  // ---- Host commands (Part 23 — replace POOL_CMD_*) -----------------------
  HOST_CMD_NONE    = $0000;
  HOST_CMD_MOUNT   = $0001;     // in: BUF=name (asciiz), DRIVE=bay
  HOST_CMD_UNMOUNT = $0002;     // in: DRIVE=bay
  HOST_CMD_LIST    = $0003;     // in: BUF=>=256B output buffer
                                //  out: name\0bay\0name\0bay\0...\0\0
                                //       bay = $FF if not currently mounted
  HOST_CMD_CREATE  = $0004;     // in: BUF=name, SECCOUNT=sectors
  HOST_CMD_DELETE  = $0005;     // in: BUF=name
  HOST_CMD_RENAME  = $0006;     // Part 24 — in: DRIVE=bay, BUF=new name
                                //   Renames bay's bound file to <new>.KOS,
                                //   keeping it open and bound. RES_OK on
                                //   success; RES_NO_MEDIA if bay empty;
                                //   RES_EXISTS if new name taken;
                                //   RES_BAD_NAME / RES_IO_ERR otherwise.
  HOST_CMD_BAYNAME = $0007;     // Part 24 — in: DRIVE=bay, BUF=≥16B output
                                //   Writes ASCIIZ basename (no .KOS) of
                                //   the bay's bound file. RES_OK or
                                //   RES_NO_MEDIA (BUF[0]=nul if empty).

  // ---- Part 25 r6: host-file load surface --------------------------------
  // Lets k/OS read arbitrary files from the LoadFolder. One file open at a
  // time (singleton state). Streaming via repeated FREAD calls; reuses the
  // existing DSK_BUF pointer for both the filename (FOPEN) and the data
  // destination (FREAD). 64 KB file-size cap (one k/OS page).
  HOST_CMD_FOPEN   = $0008;     // in:  BUF=ASCIIZ filename (no path)
                                // out: SECCOUNT=size in bytes
                                //      RES_OK / RES_NOT_FOUND / RES_BAD_NAME
                                //      RES_BUSY (already open) / RES_FULL (>64KB)
  HOST_CMD_FREAD   = $0009;     // in:  BUF=k16 destination
                                //      SECCOUNT=max bytes to read
                                // out: SECCOUNT=bytes actually read
                                //      RES_OK (0 bytes = EOF) / RES_NO_MEDIA / RES_IO_ERR
  HOST_CMD_FCLOSE  = $000A;     // out: RES_OK / RES_NO_MEDIA

  // ---- Result codes (unchanged numbers; some are no longer used) ----------
  RES_OK           = $0000;
  RES_NO_MEDIA     = $0001;
  RES_BAD_LBA      = $0002;
  RES_RO           = $0003;
  RES_IO_ERR       = $0004;
  RES_BUSY         = $0005;     // bay already in use (mount on occupied bay)
  RES_FULL         = $0006;     // list buffer too small (shouldn't happen)
  RES_EXISTS       = $0007;     // create: file already exists
  RES_NOT_FOUND    = $0008;     // mount/delete: file doesn't exist in folder
  RES_BAD_NAME     = $0009;     // bad name: empty or invalid chars
  RES_BAD_SIZE     = $000A;     // create: size below FAT-viable floor
  RES_BAD_CMD      = $00FF;

  // ---- Sizing -------------------------------------------------------------
  SECTOR_SIZE      = 512;
  MAX_DRIVES       = 4;
  MAX_NAME_LEN     = 15;        // basename without extension; 15 + ".KOS" + nul
  MIN_DISK_SECTORS = 64;        // 32 KB floor — enough for FAT16 to fit
  HOST_EXT         = '.KOS';    // extension auto-appended on lookup
  LIST_BUF_BYTES   = 256;       // size of the buffer caller supplies for LIST

  // ---- ROM disk preload (A:) ----------------------------------------------
  // A: is the k/OS ROM disk — read-only on Digital, where it lives in
  // program ROM at pages $FC..$FD. On EMU we mimic that by loading the
  // same .KOS file into RAM at $FC0000..$FDFFFF at startup, so k/OS's
  // existing _BlockReadROM path mounts it identically on both targets.
  // INI key:  [Disks] A=ROMDISK.KOS
  // Layout :  2 pages × 64 KB = 128 KB = 256 sectors of 512 bytes.
  ROMDISK_BASE_ADDR = $FC0000;
  ROMDISK_SIZE      = 131072;
  ROMDISK_INI_KEY   = 'A';

type
  TDiskDrive = record
    Stream       : TFileStream;
    FileName     : string;       // '' if empty (no media); else basename+ext
    ReadOnly     : Boolean;
    MediaChanged : Boolean;      // sticky, cleared by IDENT or MEDIA
  end;
  PDiskDrive = ^TDiskDrive;

var
  DiskDrives : array[0..MAX_DRIVES-1] of TDiskDrive;

  // Where the controller looks for / creates .KOS files.
  // Set from INI by the form on startup; default is './disk/' next to .exe.
  DiskFolder  : string = '';

  // Where the `load` command reads host-side files from (Part 25 r6).
  // Default is './load/' next to .exe. Configurable via INI [Disks] LoadPath.
  LoadFolder  : string = '';

  // Path to the INI file the controller updates on mount/unmount.
  DiskIniPath : string = '';

  // Singleton "currently open" file for HOST_CMD_FOPEN/FREAD/FCLOSE.
  // Nil when no file is open. Part 25 r6.
  HostLoadFile     : TFileStream = nil;
  HostLoadFileName : string      = '';
  HostLoadSize     : LongWord    = 0;

  // Canonical full path of the file loaded into A: ROM-disk pages, '' if
  // none. Used by LoadDiskMountsAndMount to skip a host-disk bay that
  // points at the same file (so [Disks] A=X.KOS and E=X.KOS can coexist
  // in the INI without double-binding the file).
  RomDiskFileName : string = '';

// ---- Lifecycle -------------------------------------------------------------
procedure DiskInit;
procedure DiskShutdown;

// ---- Persistent mounts (INI) ----------------------------------------------
// Reads [Disks] C/D/E/F entries and mounts each non-empty filename to its
// bay. Replaces the old LoadDiskPool + AutoMountAll pair.
procedure LoadDiskMountsAndMount(const iniFileName: string);

// ---- ROM disk preload (A:) ------------------------------------------------
// Reads [Disks] A= and, if present, loads the named .KOS file into RAM at
// $FC0000..$FDFFFF (pages $FC..$FD) so k/OS's _BlockReadROM mounts A:
// from those bytes. File must be exactly ROMDISK_SIZE bytes; missing or
// wrong-size files log a warning and leave the pages untouched (A: will
// mount-fail and show as "not mounted", matching Digital behaviour for
// an unprogrammed ROM region).
//
// Must be called BEFORE LoadDiskMountsAndMount so that host-disk bay
// loading can dedupe against the file mapped to A:.
procedure LoadRomDiskFromIni(const iniFileName: string);

// Writes current mount state back to the INI [Disks] section. Called
// automatically after every mount/unmount; safe to call externally too.
procedure SaveDiskMounts;

// ---- Direct ops (also exposed for tests / debugger) ------------------------
function  HostMount   (const baseName: string; bay: Integer): Word;
function  HostUnmount (bay: Integer): Word;
function  HostCreate  (const baseName: string; sectors: LongWord): Word;
function  HostDelete  (const baseName: string): Word;
function  HostRename  (bay: Integer; const newBase: string): Word;

// Part 25 r6 — host file load (singleton).
function  HostFOpen   (const fileName: string; out size: LongWord): Word;
function  HostFRead   (destAddr: TAddr; maxBytes: Word; out gotBytes: Word): Word;
function  HostFClose  : Word;

// ---- MMIO entry points -----------------------------------------------------
function  DiskReadIO (addr: TAddr): TWord;
procedure DiskWriteIO(addr: TAddr; v: TWord);

// ---- Log callback ----------------------------------------------------------
// Caller (frm_main.FormCreate) assigns this before LoadDiskMountsAndMount.
// All disk-subsystem messages route through it; if nil, messages drop.
// The internal Log() helper appends a newline; callers pass plain text.
//
// DiskLogVerbose controls per-sector-IO logging. Pool/mount messages
// always log if DiskLog is assigned; per-IO logging only when verbose.
type
  TDiskLogProc = procedure(const s: string);
var
  DiskLog        : TDiskLogProc = nil;
  DiskLogVerbose : Boolean      = False;

implementation

uses
  emu_mem, StrUtils;

var
  // MMIO register state
  RegDrive       : Word = 0;
  RegLBA_Lo      : Word = 0;
  RegLBA_Hi      : Word = 0;
  RegBufLo       : Word = 0;
  RegBufHi       : Word = 0;
  RegSecCount    : Word = 1;
  RegResult      : Word = RES_OK;
  RegFlags       : Word = 0;

// ===========================================================================
// Helpers
// ===========================================================================

function CurrentLBA: LongWord; inline;
begin
  Result := (LongWord(RegLBA_Hi) shl 16) or LongWord(RegLBA_Lo);
end;

function CurrentBufAddr: TAddr; inline;
begin
  Result := ((TAddr(RegBufHi) shl 16) or TAddr(RegBufLo)) and ADDR_MASK;
end;

procedure ReadStringFromRAM(addr: TAddr; maxLen: Integer; out s: string);
var
  i  : Integer;
  ch : Byte;
begin
  s := '';
  for i := 0 to maxLen - 1 do
  begin
    ch := Mem[(addr + TAddr(i)) and ADDR_MASK];
    if ch = 0 then Break;
    s := s + Char(ch);
  end;
end;

function WriteStringToRAM(addr: TAddr; const s: string): TAddr;
{ Writes ASCIIZ s to RAM at addr; returns addr advanced past the trailing
  nul (i.e. caller's next free byte). Length-clipped to MAX_NAME_LEN. }
var
  i, n : Integer;
begin
  n := Length(s);
  if n > MAX_NAME_LEN then n := MAX_NAME_LEN;
  for i := 1 to n do
    Mem[(addr + TAddr(i-1)) and ADDR_MASK] := Byte(s[i]);
  Mem[(addr + TAddr(n)) and ADDR_MASK] := 0;
  Result := (addr + TAddr(n + 1)) and ADDR_MASK;
end;

function ValidName(const s: string): Boolean;
{ Letters, digits, underscore. Non-empty, <= MAX_NAME_LEN. The basename
  only — the controller appends HOST_EXT itself. }
var i: Integer;
begin
  Result := False;
  if (s = '') or (Length(s) > MAX_NAME_LEN) then Exit;
  for i := 1 to Length(s) do
    if not (s[i] in ['A'..'Z','a'..'z','0'..'9','_']) then Exit;
  Result := True;
end;

function NormaliseName(const userInput: string): string;
{ Strip extension if present; uppercase. Returns basename. }
var
  s : string;
  p : Integer;
begin
  s := UpperCase(Trim(userInput));
  // Strip any extension the user supplied.
  p := LastDelimiter('.', s);
  if (p > 0) and SameText(Copy(s, p, MaxInt), HOST_EXT) then
    s := Copy(s, 1, p - 1);
  Result := s;
end;

function FullPath(const baseName: string): string; inline;
begin
  Result := IncludeTrailingPathDelimiter(DiskFolder) + baseName + HOST_EXT;
end;

function ValidateDrive(out d: PDiskDrive): Boolean;
begin
  Result := False;
  if RegDrive >= MAX_DRIVES then begin RegResult := RES_NO_MEDIA; Exit; end;
  d := @DiskDrives[RegDrive];
  if not Assigned(d^.Stream) then begin RegResult := RES_NO_MEDIA; Exit; end;
  Result := True;
end;

function FindBayByFile(const baseName: string): Integer;
{ Returns bay 0..3 where DiskDrives[bay].FileName matches (case-insensitive),
  or -1 if not currently mounted. }
var i: Integer;
begin
  for i := 0 to MAX_DRIVES - 1 do
    if Assigned(DiskDrives[i].Stream) and
       SameText(DiskDrives[i].FileName, baseName + HOST_EXT) then
    begin Result := i; Exit; end;
  Result := -1;
end;

procedure Log(const s: string);
begin
  if Assigned(DiskLog) then DiskLog(s + #10);
end;

const
  BAY_LETTERS : array[0..3] of Char = ('C', 'D', 'E', 'F');

function BayLetter(bay: Integer): Char; inline;
begin
  if (bay >= 0) and (bay < MAX_DRIVES) then
    Result := BAY_LETTERS[bay]
  else
    Result := '?';
end;

// ===========================================================================
// Lifecycle
// ===========================================================================

procedure DiskInit;
var i: Integer;
begin
  for i := 0 to MAX_DRIVES - 1 do
  begin
    DiskDrives[i].Stream       := nil;
    DiskDrives[i].FileName     := '';
    DiskDrives[i].ReadOnly     := False;
    DiskDrives[i].MediaChanged := False;
  end;
end;

procedure DiskShutdown;
var i: Integer;
begin
  for i := 0 to MAX_DRIVES - 1 do
    if Assigned(DiskDrives[i].Stream) then
    begin
      DiskDrives[i].Stream.Free;
      DiskDrives[i].Stream := nil;
    end;
  // Part 25 r6: also close any lingering load file.
  if Assigned(HostLoadFile) then
  begin
    HostLoadFile.Free;
    HostLoadFile := nil;
    HostLoadFileName := '';
    HostLoadSize := 0;
  end;
end;

// ===========================================================================
// Persistent mounts (INI)
// ===========================================================================

procedure SaveDiskMounts;
var
  ini : TIniFile;
  i   : Integer;
begin
  if DiskIniPath = '' then Exit;
  ini := TIniFile.Create(DiskIniPath);
  try
    // Persist disk + load folders so manual edits to the INI propagate, and
    // first-run defaults are written back instead of silently re-derived.
    // Part 25 r6: renamed `Path=` → `DiskPath=`; added `LoadPath=`.
    ini.WriteString('Disks', 'DiskPath', DiskFolder);
    ini.WriteString('Disks', 'LoadPath', LoadFolder);
    for i := 0 to MAX_DRIVES - 1 do
    begin
      if Assigned(DiskDrives[i].Stream) then
        ini.WriteString('Disks', BAY_LETTERS[i] + '', DiskDrives[i].FileName)
      else
        ini.WriteString('Disks', BAY_LETTERS[i] + '', '');
    end;
    ini.UpdateFile;
  finally
    ini.Free;
  end;
end;

// Internal: resolves [Disks] DiskPath= and LoadPath= from the INI, setting
// DiskFolder / LoadFolder if not already populated. Creates the folders on
// disk if missing. Safe to call more than once — second call is a no-op
// for any folder already set. Logging happens on the first resolution only
// (silentMode=False); when called from LoadRomDiskFromIni before the main
// loader, silentMode=True so we don't double-log when LoadDiskMountsAndMount
// runs immediately afterward.
procedure ResolveDiskFolders(const ini: TIniFile; silentMode: Boolean);
var
  pathFromIni : string;
  loadFromIni : string;
begin
  pathFromIni := Trim(ini.ReadString('Disks', 'DiskPath', ''));
  if pathFromIni <> '' then
    DiskFolder := pathFromIni
  else if DiskFolder = '' then
    DiskFolder := IncludeTrailingPathDelimiter(GetCurrentDir) + 'disk';

  if not DirectoryExists(DiskFolder) then
  begin
    try
      ForceDirectories(DiskFolder);
    except
      on E: Exception do
        Log(Format('[disk] cannot create %s: %s', [DiskFolder, E.Message]));
    end;
  end;

  if not silentMode then
    Log(Format('[disk] folder: %s', [DiskFolder]));

  loadFromIni := Trim(ini.ReadString('Disks', 'LoadPath', ''));
  if loadFromIni <> '' then
    LoadFolder := loadFromIni
  else if LoadFolder = '' then
    LoadFolder := IncludeTrailingPathDelimiter(GetCurrentDir) + 'load';

  if not DirectoryExists(LoadFolder) then
  begin
    try
      ForceDirectories(LoadFolder);
    except
      on E: Exception do
        Log(Format('[disk] cannot create %s: %s', [LoadFolder, E.Message]));
    end;
  end;

  if not silentMode then
    Log(Format('[disk] load:   %s', [LoadFolder]));
end;

procedure LoadRomDiskFromIni(const iniFileName: string);
var
  ini      : TIniFile;
  fname    : string;
  baseName : string;
  fullPath : string;
  fileSize : Int64;
  F        : TFileStream;
begin
  // Default: no ROM disk loaded.
  RomDiskFileName := '';

  ini := TIniFile.Create(iniFileName);
  try
    // Resolve folders silently — LoadDiskMountsAndMount will run right
    // after us and emit the [disk] folder/load log lines itself.
    ResolveDiskFolders(ini, True);

    fname := Trim(ini.ReadString('Disks', ROMDISK_INI_KEY, ''));
    if fname = '' then Exit;             // no A= line — leave A: unmapped

    baseName := NormaliseName(fname);
    if not ValidName(baseName) then
    begin
      Log(Format('[disk] A: bad name "%s" — A: ROM disk skipped', [fname]));
      Exit;
    end;

    fullPath := IncludeTrailingPathDelimiter(DiskFolder) + baseName + HOST_EXT;

    if not FileExists(fullPath) then
    begin
      Log(Format('[disk] A: %s not found in %s — A: will be unmounted',
                 [baseName + HOST_EXT, DiskFolder]));
      Exit;
    end;

    // Size check — file must be exactly the ROM-disk region (2 pages).
    try
      F := TFileStream.Create(fullPath, fmOpenRead or fmShareDenyWrite);
      try
        fileSize := F.Size;
      finally
        F.Free;
      end;
    except
      on E: Exception do
      begin
        Log(Format('[disk] A: cannot open %s: %s — A: ROM disk skipped',
                   [fullPath, E.Message]));
        Exit;
      end;
    end;

    if fileSize <> ROMDISK_SIZE then
    begin
      Log(Format('[disk] A: %s is %d bytes, expected %d — A: ROM disk skipped',
                 [baseName + HOST_EXT, fileSize, ROMDISK_SIZE]));
      Exit;
    end;

    // Slurp the file straight into RAM at $FC0000..$FDFFFF. MemLoadBin
    // raises on I/O failure; catch and warn rather than killing startup.
    try
      MemLoadBin(fullPath, ROMDISK_BASE_ADDR);
    except
      on E: Exception do
      begin
        Log(Format('[disk] A: load %s failed: %s — A: ROM disk skipped',
                   [fullPath, E.Message]));
        Exit;
      end;
    end;

    RomDiskFileName := ExpandFileName(fullPath);
    Log(Format('[disk] A: ROM disk loaded from %s (%d bytes)',
               [RomDiskFileName, ROMDISK_SIZE]));
  finally
    ini.Free;
  end;
end;

procedure LoadDiskMountsAndMount(const iniFileName: string);
var
  ini      : TIniFile;
  i        : Integer;
  fname    : string;
  baseName : string;
  bayFullPath : string;
begin
  DiskIniPath := iniFileName;

  ini := TIniFile.Create(iniFileName);
  try
    // [Disks] DiskPath= and LoadPath=. Logs the resolved folders.
    ResolveDiskFolders(ini, False);

    for i := 0 to MAX_DRIVES - 1 do
    begin
      fname := Trim(ini.ReadString('Disks', BAY_LETTERS[i] + '', ''));
      if fname = '' then Continue;

      // INI value can be either "FOO" or "FOO.KOS". NormaliseName strips
      // any extension and uppercases.
      baseName := NormaliseName(fname);
      if not ValidName(baseName) then
      begin
        Log(Format('[disk] %s: bad name "%s" — skipped', [BAY_LETTERS[i], fname]));
        Continue;
      end;

      // Dedupe against A: ROM disk: if this bay points at the same host
      // file we already loaded into the ROM-disk pages, don't bind it as
      // a R/W host bay too — writes via the host backend would diverge
      // from the bytes k/OS sees through _BlockReadROM.
      if RomDiskFileName <> '' then
      begin
        bayFullPath := ExpandFileName(
          IncludeTrailingPathDelimiter(DiskFolder) + baseName + HOST_EXT);
        if SameFileName(bayFullPath, RomDiskFileName) then
        begin
          Log(Format('[disk] %s: %s skipped — same file as A: ROM disk',
                     [BAY_LETTERS[i], baseName + HOST_EXT]));
          Continue;
        end;
      end;

      // HostMount logs success/failure itself; ignore the return code here.
      HostMount(baseName, i);
    end;
  finally
    ini.Free;
  end;
end;

// ===========================================================================
// Direct ops
// ===========================================================================

function HostMount(const baseName: string; bay: Integer): Word;
var
  fp : string;
begin
  if (bay < 0) or (bay >= MAX_DRIVES) then begin Result := RES_NO_MEDIA; Exit; end;
  if not ValidName(baseName) then begin Result := RES_BAD_NAME; Exit; end;
  if Assigned(DiskDrives[bay].Stream) then
  begin
    Result := RES_BUSY;
    Log(Format('[disk] mount FAILED %s: %s.KOS — bay occupied (unmount first)',
               [BayLetter(bay), baseName]));
    Exit;
  end;
  fp := FullPath(baseName);
  if not FileExists(fp) then
  begin
    Result := RES_NOT_FOUND;
    Log(Format('[disk] mount FAILED %s: %s not found',
               [BayLetter(bay), fp]));
    Exit;
  end;
  try
    DiskDrives[bay].Stream := TFileStream.Create(fp,
      fmOpenReadWrite or fmShareDenyWrite);
    DiskDrives[bay].FileName     := baseName + HOST_EXT;
    DiskDrives[bay].ReadOnly     := False;
    DiskDrives[bay].MediaChanged := True;
    SaveDiskMounts;
    Log(Format('[disk] mounted %s: %s.KOS  %d sectors',
               [BayLetter(bay), baseName,
                DiskDrives[bay].Stream.Size div SECTOR_SIZE]));
    Result := RES_OK;
  except
    on E: Exception do
    begin
      DiskDrives[bay].Stream := nil;
      DiskDrives[bay].FileName := '';
      Result := RES_IO_ERR;
      Log(Format('[disk] mount FAILED %s: %s.KOS — %s',
                 [BayLetter(bay), baseName, E.Message]));
    end;
  end;
end;

function HostUnmount(bay: Integer): Word;
var
  fname : string;
begin
  if (bay < 0) or (bay >= MAX_DRIVES) then begin Result := RES_NO_MEDIA; Exit; end;
  if not Assigned(DiskDrives[bay].Stream) then
  begin Result := RES_NO_MEDIA; Exit; end;

  fname := DiskDrives[bay].FileName;
  DiskDrives[bay].Stream.Free;
  DiskDrives[bay].Stream       := nil;
  DiskDrives[bay].FileName     := '';
  DiskDrives[bay].ReadOnly     := False;
  DiskDrives[bay].MediaChanged := True;
  SaveDiskMounts;
  Log(Format('[disk] unmounted %s: %s', [BayLetter(bay), fname]));
  Result := RES_OK;
end;

function HostCreate(const baseName: string; sectors: LongWord): Word;
var
  fp  : string;
  fs  : TFileStream;
  blk : array[0..SECTOR_SIZE-1] of Byte;
  i   : LongWord;
begin
  if not ValidName(baseName) then begin Result := RES_BAD_NAME; Exit; end;
  if sectors < MIN_DISK_SECTORS then begin Result := RES_BAD_SIZE; Exit; end;
  fp := FullPath(baseName);
  if FileExists(fp) then
  begin
    Result := RES_EXISTS;
    Log(Format('[disk] create FAILED: %s.KOS already exists', [baseName]));
    Exit;
  end;
  try
    fs := TFileStream.Create(fp, fmCreate or fmShareDenyWrite);
    try
      FillChar(blk, SizeOf(blk), 0);
      for i := 0 to sectors - 1 do
        fs.WriteBuffer(blk, SECTOR_SIZE);
    finally
      fs.Free;
    end;
    Log(Format('[disk] created %s.KOS  %d sectors (%d KB)',
               [baseName, sectors, (sectors * SECTOR_SIZE) div 1024]));
    Result := RES_OK;
  except
    on E: Exception do
    begin
      Result := RES_IO_ERR;
      Log(Format('[disk] create FAILED %s.KOS: %s', [baseName, E.Message]));
    end;
  end;
end;

function HostDelete(const baseName: string): Word;
var
  fp : string;
begin
  if not ValidName(baseName) then begin Result := RES_BAD_NAME; Exit; end;
  if FindBayByFile(baseName) >= 0 then
  begin
    Result := RES_BUSY;
    Log(Format('[disk] delete FAILED: %s.KOS still mounted', [baseName]));
    Exit;
  end;
  fp := FullPath(baseName);
  if not FileExists(fp) then
  begin Result := RES_NOT_FOUND; Exit; end;
  if DeleteFile(fp) then
  begin
    Log(Format('[disk] deleted %s.KOS', [baseName]));
    Result := RES_OK;
  end
  else
  begin
    Result := RES_IO_ERR;
    Log(Format('[disk] delete FAILED %s.KOS: OS denied', [baseName]));
  end;
end;

function HostRename(bay: Integer; const newBase: string): Word;
{ Rename the file bound to `bay` to `<newBase>.KOS`, keeping it open and
  bound on the same bay. Used by `format C: LABEL` to keep host filename
  and FAT16 label in sync, and by the kosh `rename` command.

  Strategy:
    1. Validate bay+name.
    2. Reject if new name file already exists (anywhere — different bay or
       just sitting in folder).
    3. Reject if new name == old name (no-op, but log).
    4. Close the bound stream (releases the Windows file handle).
    5. RenameFile old → new.
    6. Reopen the stream at the new path. If reopen fails (shouldn't,
       since we just closed it), the bay ends up empty.
    7. Update FileName, save INI.

  Failure mid-step leaves the bay's stream nil (no silent half-state).
  Caller should treat any non-OK result as "bay state may be empty —
  consider reissuing mount". }
var
  oldFP    : string;
  newFP    : string;
  oldBase  : string;
begin
  if (bay < 0) or (bay >= MAX_DRIVES) then
  begin Result := RES_NO_MEDIA; Exit; end;
  if not Assigned(DiskDrives[bay].Stream) then
  begin Result := RES_NO_MEDIA; Exit; end;
  if not ValidName(newBase) then
  begin Result := RES_BAD_NAME; Exit; end;

  // Old basename = FileName minus .KOS extension.
  oldBase := UpperCase(ChangeFileExt(DiskDrives[bay].FileName, ''));
  if SameText(oldBase, newBase) then
  begin
    Result := RES_OK;  // already matches — no-op
    Exit;
  end;

  newFP := FullPath(newBase);
  if FileExists(newFP) then
  begin
    Result := RES_EXISTS;
    Log(Format('[disk] rename FAILED %s: %s.KOS already exists',
               [BayLetter(bay), newBase]));
    Exit;
  end;

  oldFP := FullPath(oldBase);

  // Close before rename so Windows lets go of the handle.
  DiskDrives[bay].Stream.Free;
  DiskDrives[bay].Stream := nil;

  if not RenameFile(oldFP, newFP) then
  begin
    // Rename failed — try to reopen old name so bay isn't left empty.
    try
      DiskDrives[bay].Stream := TFileStream.Create(oldFP,
        fmOpenReadWrite or fmShareDenyWrite);
    except
      DiskDrives[bay].Stream := nil;
      DiskDrives[bay].FileName := '';
    end;
    Result := RES_IO_ERR;
    Log(Format('[disk] rename FAILED %s: %s.KOS → %s.KOS (OS denied)',
               [BayLetter(bay), oldBase, newBase]));
    Exit;
  end;

  // Rename succeeded. Reopen at new path.
  try
    DiskDrives[bay].Stream := TFileStream.Create(newFP,
      fmOpenReadWrite or fmShareDenyWrite);
    DiskDrives[bay].FileName := newBase + HOST_EXT;
    DiskDrives[bay].MediaChanged := True;
    SaveDiskMounts;
    Log(Format('[disk] renamed %s: %s.KOS → %s.KOS',
               [BayLetter(bay), oldBase, newBase]));
    Result := RES_OK;
  except
    on E: Exception do
    begin
      // Rename succeeded on disk but we can't reopen — leave bay empty.
      DiskDrives[bay].Stream := nil;
      DiskDrives[bay].FileName := '';
      SaveDiskMounts;
      Result := RES_IO_ERR;
      Log(Format('[disk] rename completed but REOPEN FAILED %s: %s.KOS — %s',
                 [BayLetter(bay), newBase, E.Message]));
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Part 25 r6 — host file load surface.
//
// Lets k/OS read host-side files from LoadFolder, typically newly-built
// .COM files dropped there by the IDE. Singleton state: one file open at
// a time. Streaming via repeated FREAD calls into a small k/OS-side buffer
// (typically the existing 512-byte CP_BUF in kosh). 64 KB file-size cap.
// ---------------------------------------------------------------------------

function HostFOpen(const fileName: string; out size: LongWord): Word;
var
  fp : string;
begin
  size := 0;
  if Assigned(HostLoadFile) then
  begin
    Result := RES_BUSY;
    Log('[disk] FOPEN failed: a file is already open (call FCLOSE first)');
    Exit;
  end;
  if (fileName = '') or (Length(fileName) > MAX_NAME_LEN) then
  begin
    Result := RES_BAD_NAME;
    Exit;
  end;
  // Reject path components — we only accept a basename in LoadFolder.
  // Defensive guard against any future path-traversal cleverness.
  if (Pos('/',  fileName) > 0) or
     (Pos('\',  fileName) > 0) or
     (Pos(':',  fileName) > 0) or
     (Pos('..', fileName) > 0) then
  begin
    Result := RES_BAD_NAME;
    Log(Format('[disk] FOPEN rejected (path chars): %s', [fileName]));
    Exit;
  end;
  fp := IncludeTrailingPathDelimiter(LoadFolder) + fileName;
  if not FileExists(fp) then
  begin
    Result := RES_NOT_FOUND;
    Log(Format('[disk] FOPEN not found: %s', [fp]));
    Exit;
  end;
  try
    HostLoadFile := TFileStream.Create(fp, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      HostLoadFile := nil;
      Result := RES_IO_ERR;
      Log(Format('[disk] FOPEN error: %s', [E.Message]));
      Exit;
    end;
  end;
  if HostLoadFile.Size > $10000 then
  begin
    Log(Format('[disk] FOPEN too large (%d bytes; max 65536): %s',
               [HostLoadFile.Size, fp]));
    HostLoadFile.Free;
    HostLoadFile := nil;
    Result := RES_FULL;
    Exit;
  end;
  HostLoadFileName := fileName;
  HostLoadSize     := HostLoadFile.Size;
  size             := HostLoadSize;
  Log(Format('[disk] FOPEN %s (%d bytes)', [fileName, HostLoadSize]));
  Result := RES_OK;
end;

function HostFRead(destAddr: TAddr; maxBytes: Word; out gotBytes: Word): Word;
var
  buf : array of Byte;
  i   : Integer;
begin
  gotBytes := 0;
  if not Assigned(HostLoadFile) then
  begin
    Result := RES_NO_MEDIA;
    Exit;
  end;
  if maxBytes = 0 then
  begin
    Result := RES_OK;       // valid no-op
    Exit;
  end;
  try
    SetLength(buf, maxBytes);
    gotBytes := Word(HostLoadFile.Read(buf[0], maxBytes));
    for i := 0 to gotBytes - 1 do
      Mem[(destAddr + LongWord(i)) and ADDR_MASK] := buf[i];
    Result := RES_OK;
    if DiskLogVerbose then
      Log(Format('[disk] FREAD %d bytes → $%.6x', [gotBytes, destAddr]));
  except
    on E: Exception do
    begin
      Result := RES_IO_ERR;
      Log(Format('[disk] FREAD error: %s', [E.Message]));
    end;
  end;
end;

function HostFClose: Word;
begin
  if not Assigned(HostLoadFile) then
  begin
    Result := RES_NO_MEDIA;
    Exit;
  end;
  Log(Format('[disk] FCLOSE %s', [HostLoadFileName]));
  HostLoadFile.Free;
  HostLoadFile := nil;
  HostLoadFileName := '';
  HostLoadSize := 0;
  Result := RES_OK;
end;


// ===========================================================================
// MMIO command handlers
// ===========================================================================

procedure DoRead;
var
  d   : PDiskDrive;
  lba : LongWord;
  buf : TAddr;
  sec : Integer;
  blk : array[0..SECTOR_SIZE-1] of Byte;
  i   : Integer;
  sz  : LongWord;
begin
  if DiskLogVerbose then
    Log(Format('[disk] CMD_READ drive=%d lba=%d buf=$%.6x count=%d',
               [RegDrive, CurrentLBA, CurrentBufAddr, RegSecCount]));
  if not ValidateDrive(d) then
  begin
    if DiskLogVerbose then
      Log(Format('  → FAIL ValidateDrive (RegResult=%d)', [RegResult]));
    Exit;
  end;
  lba := CurrentLBA;
  buf := CurrentBufAddr;
  sz  := LongWord(d^.Stream.Size) div SECTOR_SIZE;
  if (lba + RegSecCount) > sz then
  begin
    RegResult := RES_BAD_LBA;
    if DiskLogVerbose then
      Log(Format('  → FAIL BAD_LBA (disk=%d sectors)', [sz]));
    Exit;
  end;
  try
    d^.Stream.Position := Int64(lba) * SECTOR_SIZE;
    for sec := 0 to RegSecCount - 1 do
    begin
      d^.Stream.ReadBuffer(blk, SECTOR_SIZE);
      for i := 0 to SECTOR_SIZE - 1 do
        Mem[(buf + TAddr(sec * SECTOR_SIZE + i)) and ADDR_MASK] := blk[i];
    end;
    RegResult := RES_OK;
    if DiskLogVerbose then Log('  → OK');
  except
    on E: Exception do
    begin
      RegResult := RES_IO_ERR;
      if DiskLogVerbose then
        Log(Format('  → FAIL IO_ERR (%s)', [E.Message]));
    end;
  end;
end;

procedure DoWrite;
var
  d   : PDiskDrive;
  lba : LongWord;
  buf : TAddr;
  sec : Integer;
  blk : array[0..SECTOR_SIZE-1] of Byte;
  i   : Integer;
  sz  : LongWord;
begin
  if not ValidateDrive(d) then Exit;
  if d^.ReadOnly then begin RegResult := RES_RO; Exit; end;
  lba := CurrentLBA;
  buf := CurrentBufAddr;
  sz  := LongWord(d^.Stream.Size) div SECTOR_SIZE;
  if (lba + RegSecCount) > sz then begin RegResult := RES_BAD_LBA; Exit; end;
  try
    d^.Stream.Position := Int64(lba) * SECTOR_SIZE;
    for sec := 0 to RegSecCount - 1 do
    begin
      for i := 0 to SECTOR_SIZE - 1 do
        blk[i] := Mem[(buf + TAddr(sec * SECTOR_SIZE + i)) and ADDR_MASK];
      d^.Stream.WriteBuffer(blk, SECTOR_SIZE);
    end;
    RegResult := RES_OK;
  except
    RegResult := RES_IO_ERR;
  end;
end;

procedure DoIdent;
var
  d  : PDiskDrive;
  sz : LongWord;
begin
  if not ValidateDrive(d) then begin RegSecCount := 0; RegFlags := 0; Exit; end;
  sz := LongWord(d^.Stream.Size) div SECTOR_SIZE;
  if sz > $FFFF then RegSecCount := $FFFF else RegSecCount := Word(sz);
  RegFlags := $0001;
  if d^.ReadOnly then RegFlags := RegFlags or $0002;
  d^.MediaChanged := False;
  RegResult := RES_OK;
end;

procedure DoFormat;
var
  d   : PDiskDrive;
  blk : array[0..SECTOR_SIZE-1] of Byte;
  i   : LongWord;
  sz  : LongWord;
begin
  if not ValidateDrive(d) then Exit;
  if d^.ReadOnly then begin RegResult := RES_RO; Exit; end;
  FillChar(blk, SizeOf(blk), 0);
  sz := LongWord(d^.Stream.Size) div SECTOR_SIZE;
  try
    d^.Stream.Position := 0;
    for i := 0 to sz - 1 do
      d^.Stream.WriteBuffer(blk, SECTOR_SIZE);
    RegResult := RES_OK;
  except
    RegResult := RES_IO_ERR;
  end;
end;

procedure DoMedia;
var d: PDiskDrive;
begin
  if RegDrive >= MAX_DRIVES then begin RegResult := RES_NO_MEDIA; Exit; end;
  d := @DiskDrives[RegDrive];
  RegFlags := 0;
  if Assigned(d^.Stream) then RegFlags := RegFlags or $0001;
  if d^.ReadOnly then         RegFlags := RegFlags or $0002;
  if d^.MediaChanged then     RegFlags := RegFlags or $0004;
  d^.MediaChanged := False;
  RegResult := RES_OK;
end;

// ---- Host management commands --------------------------------------------

procedure DoHostMount;
var
  name : string;
begin
  ReadStringFromRAM(CurrentBufAddr, MAX_NAME_LEN, name);
  name := NormaliseName(name);
  RegResult := HostMount(name, RegDrive);
end;

procedure DoHostUnmount;
begin
  RegResult := HostUnmount(RegDrive);
end;

procedure DoHostCreate;
var
  name : string;
begin
  ReadStringFromRAM(CurrentBufAddr, MAX_NAME_LEN, name);
  name := NormaliseName(name);
  RegResult := HostCreate(name, RegSecCount);
end;

procedure DoHostDelete;
var
  name : string;
begin
  ReadStringFromRAM(CurrentBufAddr, MAX_NAME_LEN, name);
  name := NormaliseName(name);
  RegResult := HostDelete(name);
end;

procedure DoHostRename;
var
  newName : string;
begin
  ReadStringFromRAM(CurrentBufAddr, MAX_NAME_LEN, newName);
  newName := NormaliseName(newName);
  RegResult := HostRename(RegDrive, newName);
end;

procedure DoHostBayName;
{ Write the basename (no .KOS extension) of the bay's bound file into
  the caller's buffer as ASCIIZ. Used by kosh's `format <drive>` (no
  label) to default the FAT16 label to the host filename. }
var
  bay   : Integer;
  base  : string;
begin
  bay := RegDrive;
  if (bay < 0) or (bay >= MAX_DRIVES) or
     not Assigned(DiskDrives[bay].Stream) then
  begin
    // Empty bay — write a single nul so caller sees ASCIIZ "".
    Mem[CurrentBufAddr and ADDR_MASK] := 0;
    RegResult := RES_NO_MEDIA;
    Exit;
  end;
  base := UpperCase(ChangeFileExt(DiskDrives[bay].FileName, ''));
  WriteStringToRAM(CurrentBufAddr, base);
  RegResult := RES_OK;
end;

procedure DoHostFOpen;
{ Read ASCIIZ filename from BUF, open the host file in LoadFolder.
  On RES_OK, SECCOUNT holds the file size in bytes (capped at 64 KB). }
var
  name : string;
  size : LongWord;
begin
  ReadStringFromRAM(CurrentBufAddr, MAX_NAME_LEN, name);
  // No NormaliseName here — `load` accepts the full filename including
  // extension, unlike the .KOS mount commands.
  RegResult := HostFOpen(name, size);
  if RegResult = RES_OK then
    RegSecCount := Word(size);
end;

procedure DoHostFRead;
{ Read up to SECCOUNT bytes from the current load-file cursor into BUF.
  On RES_OK, SECCOUNT is updated to bytes actually read (0 = EOF). }
var
  got : Word;
begin
  RegResult := HostFRead(CurrentBufAddr, RegSecCount, got);
  RegSecCount := got;
end;

procedure DoHostFClose;
begin
  RegResult := HostFClose;
end;

procedure DoHostList;
{ Walk DiskFolder for *.KOS files, dump as
    name\0bay\0name\0bay\0...\0\0
  into the caller's buffer. bay byte = 0..3 if currently mounted, $FF
  otherwise. Names alphabetised case-insensitively.

  Hard cap LIST_BUF_BYTES = 256 bytes total. If we'd overflow, stop and
  return RES_OK with what we have (sentinel still written). Caller is
  expected to size its buffer at LIST_BUF_BYTES. }
var
  buf       : TAddr;
  used      : Integer;
  sr        : TSearchRec;
  found     : TStringList;
  i, k      : Integer;
  baseName  : string;
  bay       : Integer;
  fileName  : string;

  function CanFit(extraBytes: Integer): Boolean;
  begin
    Result := (used + extraBytes + 1) <= LIST_BUF_BYTES;
  end;

begin
  buf  := CurrentBufAddr;
  used := 0;

  found := TStringList.Create;
  try
    found.Sorted := False;
    if FindFirst(IncludeTrailingPathDelimiter(DiskFolder) + '*' + HOST_EXT,
                 faAnyFile and (not faDirectory), sr) = 0 then
    begin
      try
        repeat
          if (sr.Attr and faDirectory) = 0 then
          begin
            // Strip extension, uppercase.
            fileName := UpperCase(ChangeFileExt(sr.Name, ''));
            if ValidName(fileName) then
              found.Add(fileName);
          end;
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;

    // Sort case-insensitively (Windows names are case-insensitive anyway).
    // Part 24 fix: previous code passed @CompareText to CustomSort, but
    // CompareText's signature doesn't match TStringListSortCompare —
    // CustomSort would pass (List, Index1, Index2) and CompareText would
    // dereference them as strings, corrupting the stack. The bug was
    // invisible with 1–2 files (degenerate sort, no comparisons run) but
    // hung the CPU thread once the folder had 3+ files.
    // Names are already UpperCase from line 730, so plain Sort is fine.
    found.CaseSensitive := False;
    found.Sort;

    for i := 0 to found.Count - 1 do
    begin
      baseName := found[i];

      // Need: len(baseName) + 1 (nul) + 1 (bay byte) bytes
      if not CanFit(Length(baseName) + 2) then Break;

      // Write name
      for k := 1 to Length(baseName) do
      begin
        Mem[(buf + TAddr(used)) and ADDR_MASK] := Byte(baseName[k]);
        Inc(used);
      end;
      Mem[(buf + TAddr(used)) and ADDR_MASK] := 0;
      Inc(used);

      // Write bay byte (followed by its own nul terminator pair-element).
      // Format: name\0bay\0name\0bay\0... so caller walks it as a stream
      // of (name, byte) pairs separated by \0's at known positions.
      bay := FindBayByFile(baseName);
      if bay < 0 then
        Mem[(buf + TAddr(used)) and ADDR_MASK] := $FF
      else
        Mem[(buf + TAddr(used)) and ADDR_MASK] := Byte(bay);
      Inc(used);

      // Pair-separator nul (so caller's parser is uniform)
      Mem[(buf + TAddr(used)) and ADDR_MASK] := 0;
      Inc(used);
    end;

    // Final sentinel: a second nul (so caller sees \0\0 end-of-list).
    if used < LIST_BUF_BYTES then
    begin
      Mem[(buf + TAddr(used)) and ADDR_MASK] := 0;
      Inc(used);
    end;

    RegResult := RES_OK;
  finally
    found.Free;
  end;
end;

// ===========================================================================
// MMIO dispatch
// ===========================================================================

function DiskReadIO(addr: TAddr): TWord;
begin
  case addr of
    DSK_CMD       : Result := 0;
    DSK_STATUS    : Result := 0;
    DSK_DRIVE     : Result := RegDrive;
    DSK_LBA_LO    : Result := RegLBA_Lo;
    DSK_LBA_HI    : Result := RegLBA_Hi;
    DSK_BUF_LO    : Result := RegBufLo;
    DSK_BUF_HI    : Result := RegBufHi;
    DSK_SECCOUNT  : Result := RegSecCount;
    DSK_RESULT    : Result := RegResult;
    DSK_FLAGS     : Result := RegFlags;
  else            Result := 0;
  end;
end;

procedure DiskWriteIO(addr: TAddr; v: TWord);
begin
  case addr of
    DSK_DRIVE     : RegDrive    := v and $0003;
    DSK_LBA_LO    : RegLBA_Lo   := v;
    DSK_LBA_HI    : RegLBA_Hi   := v and $00FF;
    DSK_BUF_LO    : RegBufLo    := v;
    DSK_BUF_HI    : RegBufHi    := v and $00FF;
    DSK_SECCOUNT  : RegSecCount := v;
    DSK_FLAGS     : RegFlags    := v;
    DSK_CMD       :
      begin
        case v of
          CMD_READ   : DoRead;
          CMD_WRITE  : DoWrite;
          CMD_IDENT  : DoIdent;
          CMD_FLUSH  : RegResult := RES_OK;
          CMD_FORMAT : DoFormat;
          CMD_MEDIA  : DoMedia;
          CMD_NONE   : ;
        else           RegResult := RES_BAD_CMD;
        end;
      end;
    DSK_HOST_CMD  :
      begin
        case v of
          HOST_CMD_MOUNT   : DoHostMount;
          HOST_CMD_UNMOUNT : DoHostUnmount;
          HOST_CMD_LIST    : DoHostList;
          HOST_CMD_CREATE  : DoHostCreate;
          HOST_CMD_DELETE  : DoHostDelete;
          HOST_CMD_RENAME  : DoHostRename;
          HOST_CMD_BAYNAME : DoHostBayName;
          HOST_CMD_FOPEN   : DoHostFOpen;
          HOST_CMD_FREAD   : DoHostFRead;
          HOST_CMD_FCLOSE  : DoHostFClose;
          HOST_CMD_NONE    : ;
        else                 RegResult := RES_BAD_CMD;
        end;
      end;
  end;
end;

end.
