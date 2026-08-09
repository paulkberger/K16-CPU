// k16-core.js — K16 execution core. Ties the units together and drives them.
//
// This is the inner body of TCPUThread.Execute (cpu_thread.pas) with the FPC
// threading/throttle removed: the web front-end paces by calling step(budget)
// once per animation frame. What's preserved: fetch -> dispatch -> cycle accrual,
// the magic-NOP $00FF breakpoint, the odd-PC halt, and hardware IRQ injection.
//
// Owns one instance each of mem/cpu/alu/opcodes and a reusable decoded record.
// The front-end loads images via core.mem.loadHex/loadBytes, then core.reset().
//
// Load order: types, cpu, mem, alu, decode, opcodes, then this file.

(function (root) {
  'use strict';

  const req = (typeof require === 'function');
  const T          = req ? require('./k16-types.js')   : root.K16Types;
  const K16CPU     = req ? require('./k16-cpu.js')      : root.K16CPU;
  const K16Mem     = req ? require('./k16-mem.js')      : root.K16Mem;
  const K16ALU     = req ? require('./k16-alu.js')      : root.K16ALU;
  const K16Decode  = req ? require('./k16-decode.js')   : root.K16Decode;
  const K16Opcodes = req ? require('./k16-opcodes.js')  : root.K16Opcodes;

  const { ADDR_MASK, RESET_VEC } = T;
  const MAGIC_NOP = 0x00FF;        // EMU breakpoint sentinel (Digital ignores it)

  class K16Core {
    constructor() {
      this.mem = new K16Mem();
      this.cpu = new K16CPU(this.mem);
      this.alu = new K16ALU(this.cpu);
      this.ops = new K16Opcodes(this.cpu, this.mem, this.alu);
      this.d   = K16Decode.newDecoded();

      this.breakEnabled = false;
      this.breakAddr    = 0;

      // Pause signals the front-end reads after step() returns.
      this.breakpointHit = false;
      this.magicNopHit   = false;
      this._justHitBp    = false;

      // Execution trace ring — last N retired instruction addresses + the cycle
      // count at retire. Each frame runs millions of instructions but the panels
      // only sample at frame boundaries, so foreground bursts (a keystroke waking
      // the shell, then back to the idle wait) happen entirely between samples and
      // are invisible. The ring captures the *tail* of what actually executed, so
      // Pause/Step can show the path that led to the stop, not just the resting PC.
      // Execution trace ring — the last few retired instruction addresses, used
      // ONLY to render the greyed "before" lines above the PC in the disassembler
      // (the one thing forward-decode can't get right across a branch). Tiny depth
      // (we show ~3-4 before lines) and GATED: traceOn is set from the "Update
      // disassembler" checkbox, so when you're not watching, the write is skipped
      // and the core runs at full speed. Power-of-two depth → cheap mask.
      this.traceOn   = false;
      this.TRACE_CAP = 8;
      this._trMask   = this.TRACE_CAP - 1;
      this._trPC     = new Uint32Array(this.TRACE_CAP);
      this._trHead   = 0;                                  // next write slot
      this._trCount  = 0;                                  // valid entries (caps at CAP)
    }

    reset() {
      this.cpu.reset();                 // PC <- RESET_VEC, regs/flags cleared
      this.breakpointHit = false;
      this.magicNopHit   = false;
      this._justHitBp    = false;
      this._trHead = 0; this._trCount = 0;   // drop the trace
    }

    // Last n retired instruction addresses, oldest -> newest. (The ring write is
    // inlined at the two execute sites for speed; this is the read side.)
    getTrace(n) {
      n = Math.min(n | 0, this._trCount);
      const out = [];
      let idx = (this._trHead - n) & this._trMask;
      for (let i = 0; i < n; i++) { out.push(this._trPC[idx]); idx = (idx + 1) & this._trMask; }
      return out;
    }

    // Raise a hardware interrupt (front-end vblank timer calls this). Honoured
    // after the next retired instruction when IE is set.
    requestIRQ() { this.cpu.IRQPending = 1; }

    setBreakpoint(addr) { this.breakAddr = addr & ADDR_MASK; this.breakEnabled = true; }
    clearBreakpoint()   { this.breakEnabled = false; }

    // Execute exactly one instruction (Step button). Ignores the magic-NOP
    // pause so the user can step past it; still services a pending IRQ.
    stepInstruction() {
      const cpu = this.cpu, d = this.d;
      const start = cpu.CycleCount;
      if (cpu.Halted) return 0;
      const pc0 = cpu.PC;
      K16Decode.fetch(cpu, this.mem, d);
      this.ops.exec(d);
      cpu.CycleCount += d.cycles;
      this._trPC[this._trHead] = pc0;                         // step always records
      this._trHead = (this._trHead + 1) & this._trMask;
      if (this._trCount < this.TRACE_CAP) this._trCount++;
      this._serviceIRQ();
      this._justHitBp = false;
      return cpu.CycleCount - start;
    }

    // Run until ~budget cycles consumed, or halt, or a breakpoint/magic-NOP
    // pause. Returns cycles actually consumed.
    step(budget) {
      const cpu = this.cpu, mem = this.mem, ops = this.ops, d = this.d;
      const start = cpu.CycleCount;
      this.breakpointHit = false;
      this.magicNopHit   = false;

      while ((cpu.CycleCount - start) < budget) {
        if (cpu.Halted) break;

        // PC breakpoint — pause before fetching the instruction at breakAddr.
        if (this.breakEnabled && !this._justHitBp && cpu.PC === this.breakAddr) {
          this.breakpointHit = true;
          this._justHitBp = true;
          break;
        }

        const pc0 = cpu.PC;
        K16Decode.fetch(cpu, mem, d);

        // Magic NOP $00FF — rewind so it hasn't executed, pause to debugger.
        if (cpu.IR === MAGIC_NOP && !this._justHitBp) {
          cpu.PC = (cpu.PC - 2) & ADDR_MASK;
          this.magicNopHit = true;
          this.breakpointHit = true;
          this._justHitBp = true;
          break;
        }

        ops.exec(d);
        cpu.CycleCount += d.cycles;
        if (this.traceOn) {                                  // gated trace write
          this._trPC[this._trHead] = pc0;
          this._trHead = (this._trHead + 1) & this._trMask;
          if (this._trCount < this.TRACE_CAP) this._trCount++;
        }
        this._justHitBp = false;

        this._serviceIRQ();
        // A code/data fault during this instruction sets Halted; the loop top
        // catches it next iteration (matching the FPC ordering).
      }
      return cpu.CycleCount - start;
    }

    // Hardware IRQ: fabricate an INT ($1F,3) exactly as the FPC loop does when
    // IRQPending is latched and interrupts are enabled.
    _serviceIRQ() {
      const cpu = this.cpu, d = this.d;
      if (cpu.IE && cpu.IRQPending !== 0) {
        cpu.IRQPending = 0;
        d.opcode = 0x1F; d.mode = 3; d.cycles = 16;
        this.ops.exec(d);
        cpu.CycleCount += 16;
      }
    }

    // Snapshot in the Core.state shape from the Part 2 handover.
    getState() {
      const c = this.cpu;
      return {
        D:  [c.D[0], c.D[1], c.D[2], c.D[3]],
        XY: [c.xyGet(0), c.xyGet(1), c.xyGet(2), c.xyGet(3)],
        PC: c.PC,
        SR: { C: c.C, Z: c.Z, N: c.N, V: c.V, I: c.IE },
        cycles: c.CycleCount,
        halted: c.Halted,
        haltCode: c.HaltCode
      };
    }
  }

  K16Core.RESET_VEC = RESET_VEC;

  root.K16Core = K16Core;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16Core;

})(typeof window !== 'undefined' ? window : globalThis);
