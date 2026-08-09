(* ==============================================================================
  files.pas -- k/OS file I/O for K16 Pascal   (--kos target only)
  ------------------------------------------------------------------------------
  Include in a program with:   {$I files.pas}

  Backed by the RTL wrappers __initfiles/__fopen/__fread/__fwrite/__fclose in
  k16_rtl_kos.asm, which adapt the Pascal V2 ABI to the k/OS file syscalls
  (TRAP_OPEN 60 / CLOSE 61 / READ 62 / WRITE 63) and convert the length-prefixed
  Pascal path string to the ASCIIZ path the kernel expects.

  Usage sketch:
      InitFiles;                              { once, before the first FileOpen }
      fd := FileOpen('B:NOTES.TXT', FOPEN_READ);
      if fd >= 0 then
      begin
        n := FileRead(fd, @Buf[0], 256);      { n = bytes read, 0 = EOF, -1 = err }
        FileClose(fd);
      end;

  Paths are drive-qualified and absolute (e.g. 'B:NOTES.TXT', 'RAM:SRC\ED.PAS').
  All calls return -1 on error (fd, byte count); FileClose has no result.
  ============================================================================== *)

const
  FOPEN_READ   = $0001;   { open for reading                         }
  FOPEN_WRITE  = $0002;   { open for writing                         }
  FOPEN_CREATE = $0004;   { create if it does not exist              }
  FOPEN_TRUNC  = $0008;   { truncate to zero length on open          }
  FOPEN_APPEND = $0010;   { seek to end before each write            }

{ Zero the per-task file-descriptor table. A freshly loaded .COM inherits
  whatever was resident in its page, so this MUST run once before the first
  FileOpen, or open/read/write hit stale fd state. }
procedure InitFiles;                                              external '__initfiles';

{ Open Path with the given FOPEN_* flag bits. Returns an fd (0..7) or -1. }
function  FileOpen(Path: String; Flags: Integer): Integer;        external '__fopen';

{ Read up to Count bytes from Fd into the buffer at Buf.
  Returns the number of bytes read (0 = end of file) or -1 on error. }
function  FileRead(Fd: Integer; Buf: Pointer; Count: Integer): Integer;   external '__fread';

{ Write Count bytes from the buffer at Buf to Fd.
  Returns the number of bytes written or -1 on error. }
function  FileWrite(Fd: Integer; Buf: Pointer; Count: Integer): Integer;  external '__fwrite';

{ Close Fd. On a dirty write handle the kernel flushes size + directory entry. }
procedure FileClose(Fd: Integer);                                 external '__fclose';
