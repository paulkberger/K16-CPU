# K16 Documentation

The **K16** is a complete custom 16-bit CPU built from discrete TTL logic, with a 24-bit address space and a ROM-based ALU and microcode store. Around it sits a full software stack: an assembler, the K16Pascal compiler, the preemptive-multitasking **k/OS** operating system with its `kosh` shell, the KGFX graphics library, and Forth and BASIC environments.

This page is the home for the K16 manuals. Select a document to read it here in the panel; use **Home** to return.

---

## Start here

- [Getting Started](GETTING_STARTED.md) — build the toolchain, assemble a program, run it on the emulator.

## Processor

- [K16 Reference Manual](K16_Reference_Manual_v3_16.md) — the ISA: instruction set, addressing modes, registers, flags, timing, and the assembler.

## Operating system

- [k/OS Reference Manual](K16%20OS/Docs/kOS_Reference_Manual_v0_24.md) — kernel, syscalls, scheduling, `kosh` shell, and the OS programming model.
- [k/OS Filesystem Reference](K16%20OS/kfs/kOS_FS_Reference_v1_14.md) — the VFAT/LFN filesystem, directory layout, and disk on-media format.

## Libraries and graphics

- [KLIB Reference](K16%20OS/klib/kOS_KLIB_Reference_v1_6.md) — the shared library jump table and its routines.
- [KGFX Reference](KGFX_Reference.md) — the graphics library: regions, fonts, drawing, and scrolling. **(not uploaded yet)** 

## Languages

- [K16 Forth](K16%20Forth/K16_Forth_v3_0_Reference_Manual.md) — the Forth environment and word set.
- [K16 BASIC](K16%20Basic/K16_BASIC_v2_3_Commands.md) — the BASIC interpreter and commands.

---

## Source

- [Source repository on GitHub](https://github.com/paulkberger/K16-CPU) — full source, emulator, and toolchain.

*K16 is MIT licensed.*
