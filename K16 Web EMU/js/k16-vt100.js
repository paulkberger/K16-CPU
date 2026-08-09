/*
 * K16emu-vt100.js  —  VT100/ANSI terminal engine for the K16 web emulator
 *
 * DOM-free, classic <script> (loads on file:// in Chrome; no ES module / CORS).
 * Single source of truth for the parser: ported 1:1 from the desktop
 * emu_terminal.pas (TK16Terminal) so the web terminal and the FPC EMU agree.
 * Rendering, palette/colour scheme, scrollbar, selection, clipboard and
 * keyboard stay in the host — this engine only turns console bytes into a
 * cell grid + cursor. Attributes are emitted as byte indices (fg/bg 0..15),
 * exactly like Pascal's TAttr; the host maps indices to colours.
 *
 * Usage (browser):
 *   const vt = new VT100(80, 25);
 *   vt.write(byte);            // or vt.writeString("hi\r\n")
 *   const c = vt.cellAt(r, k); // {ch, fg, bg, bold, rev}  (honours scrollback)
 *   vt.curX, vt.curY, vt.curVis
 *
 * Usage (Node, differential test):
 *   const VT100 = require('./K16emu-vt100.js');
 *   ... feed same byte stream as FPC, compare vt.dump()
 */
(function (root) {
  'use strict';

  var SCROLLBACK_LINES = 1024;
  var DEF_FG = 0;   // black   (matches emu_terminal.pas)
  var DEF_BG = 7;   // white

  function VT100(cols, rows, scrollback, maxRows) {
    this.cols = cols || 80;
    this.rows = rows || 25;
    this.onReply = null;   // host wires this to inject a reply into the key ring (DSR)
    this.scrollback = (scrollback == null) ? SCROLLBACK_LINES : scrollback;
    this.maxRows = Math.max(this.rows, maxRows || 240);  // visible rows may grow up to this
    this._alloc();
    this.reset();
  }

  // ---- cell helpers -------------------------------------------------------
  function blankCell() { return { ch: ' ', fg: DEF_FG, bg: DEF_BG, bold: false, rev: false }; }
  function cloneCell(c) { return { ch: c.ch, fg: c.fg, bg: c.bg, bold: c.bold, rev: c.rev }; }

  VT100.prototype._alloc = function () {
    this.total = this.scrollback + this.maxRows;   // FTotalLines (fixed ring capacity)
    this.buf = new Array(this.total);
    for (var r = 0; r < this.total; r++) {
      var row = new Array(this.cols);
      for (var c = 0; c < this.cols; c++) row[c] = blankCell();
      this.buf[r] = row;
    }
  };

  // ring index of a visible row (0..rows-1). Matches RingRow().
  VT100.prototype._ring = function (visRow) {
    var idx = this.writeRow - this.rows + visRow;
    idx = idx % this.total;
    if (idx < 0) idx += this.total;
    return idx;
  };

  VT100.prototype._blankRingRow = function (ringIdx) {
    ringIdx = ((ringIdx % this.total) + this.total) % this.total;
    var row = this.buf[ringIdx];
    for (var c = 0; c < this.cols; c++) {
      var b = blankCell(); row[c].ch = b.ch; row[c].fg = b.fg; row[c].bg = b.bg;
      row[c].bold = b.bold; row[c].rev = b.rev;
    }
  };

  // erase a range using the CURRENT attr's fg/bg (per BlankVisRange).
  VT100.prototype._blankVisRange = function (visRow, c1, c2) {
    var ri = this._ring(visRow), row = this.buf[ri];
    for (var c = c1; c <= c2; c++) {
      if (c >= 0 && c < this.cols) {
        row[c].ch = ' '; row[c].fg = this.attr.fg; row[c].bg = this.attr.bg;
        row[c].bold = false; row[c].rev = false;
      }
    }
  };

  // ---- scrolling ----------------------------------------------------------
  // Region scroll copies cell contents in place (no array aliasing). The
  // top=0 fast path advances writeRow and blanks one row, exactly like the
  // desktop ring. See note in the handover re: desktop dyn-array assignment.
  VT100.prototype._scrollUp = function (top, bot) {
    if (top === 0) {
      this.writeRow++;                                   // ring advances
      this._blankRingRow((this.writeRow - 1) % this.total);
      if (this.viewOffset > 0) {                         // sticky: keep view anchored
        var cap = this.total - this.rows;
        if (this.viewOffset < cap) this.viewOffset++;    // clamp -> overflow loses oldest
      }
    } else {
      for (var r = top; r <= bot - 1; r++) {
        var dst = this.buf[this._ring(r)], src = this.buf[this._ring(r + 1)];
        for (var c = 0; c < this.cols; c++) {
          dst[c].ch = src[c].ch; dst[c].fg = src[c].fg; dst[c].bg = src[c].bg;
          dst[c].bold = src[c].bold; dst[c].rev = src[c].rev;
        }
      }
      this._blankRingRow(this._ring(bot));
    }
  };

  VT100.prototype._scrollDown = function (top, bot) {
    for (var r = bot; r >= top + 1; r--) {
      var dst = this.buf[this._ring(r)], src = this.buf[this._ring(r - 1)];
      for (var c = 0; c < this.cols; c++) {
        dst[c].ch = src[c].ch; dst[c].fg = src[c].fg; dst[c].bg = src[c].bg;
        dst[c].bold = src[c].bold; dst[c].rev = src[c].rev;
      }
    }
    this._blankRingRow(this._ring(top));
  };

  // ESC[3J — clear scrollback, keep visible window. (SaveAndCompactVisible)
  VT100.prototype._saveAndCompactVisible = function () {
    if (this.total === 0) return;
    var snap = [], r, c;
    for (r = 0; r < this.rows; r++) {
      var line = new Array(this.cols), ri = this._ring(r);
      for (c = 0; c < this.cols; c++) line[c] = cloneCell(this.buf[ri][c]);
      snap.push(line);
    }
    for (r = 0; r < this.total; r++) this._blankRingRow(r);
    for (r = 0; r < this.rows; r++)
      for (c = 0; c < this.cols; c++) this.buf[r][c] = snap[r][c];
    this.writeRow = this.rows;
    this.viewOffset = 0;
  };

  // ---- cursor motion ------------------------------------------------------
  VT100.prototype._advance = function () {
    this.curX++;
    if (this.curX >= this.cols) { this.curX = 0; this._doLF(); }
  };
  VT100.prototype._doLF = function () {
    if (this.curY >= this.scrollBot) this._scrollUp(this.scrollTop, this.scrollBot);
    else if (this.curY < this.rows - 1) this.curY++;
  };
  VT100.prototype._doCR = function () { this.curX = 0; };
  VT100.prototype._doBS = function () { if (this.curX > 0) this.curX--; };
  VT100.prototype._doTab = function () {
    this.curX = (((this.curX / 8) | 0) + 1) * 8;
    if (this.curX >= this.cols) this.curX = this.cols - 1;
  };

  // ---- parameter accessor (P) --------------------------------------------
  VT100.prototype._P = function (idx, def) {
    if (idx < this.paramCount && this.params[idx] !== 0) return this.params[idx];
    return def;
  };

  // ---- CSI / DEC / SGR ----------------------------------------------------
  VT100.prototype._doCSI = function (fb) {
    this.wrapNext = false;
    var n, r, c, ch = String.fromCharCode(fb);
    switch (ch) {
      case 'A': this.curY = Math.max(this.scrollTop, this.curY - this._P(0, 1)); break;
      case 'B': this.curY = Math.min(this.scrollBot, this.curY + this._P(0, 1)); break;
      case 'C': this.curX = Math.min(this.cols - 1, this.curX + this._P(0, 1)); break;
      case 'D': this.curX = Math.max(0, this.curX - this._P(0, 1)); break;
      case 'E': this.curX = 0; this.curY = Math.min(this.rows - 1, this.curY + this._P(0, 1)); break;
      case 'F': this.curX = 0; this.curY = Math.max(0, this.curY - this._P(0, 1)); break;
      case 'G': this.curX = Math.max(0, Math.min(this.cols - 1, this._P(0, 1) - 1)); break;
      case 'H': case 'f':
        this.curY = Math.max(0, Math.min(this.rows - 1, this._P(0, 1) - 1));
        this.curX = Math.max(0, Math.min(this.cols - 1, this._P(1, 1) - 1));
        break;
      case 'J':
        switch (this._P(0, 0)) {
          case 0:
            this._blankVisRange(this.curY, this.curX, this.cols - 1);
            for (r = this.curY + 1; r < this.rows; r++) this._blankVisRange(r, 0, this.cols - 1);
            break;
          case 1:
            this._blankVisRange(this.curY, 0, this.curX);
            for (r = 0; r < this.curY; r++) this._blankVisRange(r, 0, this.cols - 1);
            break;
          case 2:  // ESC[2J — clear screen. VT100 keeps scrollback on 2J, but the
            // WebEMU renders the whole document (history + screen) into one
            // scrollable element, so a bare blank-in-place would leave the old
            // scrollback — including the oldest line — visible at the top. k/OS's
            // sys_clear sends 2J+H without 3J, so collapse the scrollback here:
            // drop history (keep nothing), then blank the screen. Cursor unmoved
            // (k/OS's following ESC[H homes it). Repaint's 3J+2J is idempotent.
            this._saveAndCompactVisible();                       // history -> 0, screen kept
            for (r = 0; r < this.rows; r++) this._blankRingRow(this._ring(r));
            break;
          case 3:  // erase scrollback, keep visible window
            this._saveAndCompactVisible();
            break;
        }
        break;
      case 'K':
        switch (this._P(0, 0)) {
          case 0: this._blankVisRange(this.curY, this.curX, this.cols - 1); break;
          case 1: this._blankVisRange(this.curY, 0, this.curX); break;
          case 2: this._blankVisRange(this.curY, 0, this.cols - 1); break;
        }
        break;
      case 'L': n = this._P(0, 1); for (r = 1; r <= n; r++) this._scrollDown(this.curY, this.scrollBot); break;
      case 'M': n = this._P(0, 1); for (r = 1; r <= n; r++) this._scrollUp(this.curY, this.scrollBot); break;
      case 'P':
        n = this._P(0, 1);
        var row = this.buf[this._ring(this.curY)];
        for (c = this.curX; c <= this.cols - 1 - n; c++) {
          row[c].ch = row[c + n].ch; row[c].fg = row[c + n].fg; row[c].bg = row[c + n].bg;
          row[c].bold = row[c + n].bold; row[c].rev = row[c + n].rev;
        }
        this._blankVisRange(this.curY, this.cols - n, this.cols - 1);
        break;
      case 'S': n = this._P(0, 1); for (r = 1; r <= n; r++) this._scrollUp(this.scrollTop, this.scrollBot); break;
      case 'T': n = this._P(0, 1); for (r = 1; r <= n; r++) this._scrollDown(this.scrollTop, this.scrollBot); break;
      case 'r':
        this.scrollTop = Math.max(0, Math.min(this.rows - 2, this._P(0, 1) - 1));
        this.scrollBot = Math.max(this.scrollTop + 1, Math.min(this.rows - 1, this._P(1, this.rows) - 1));
        this.curX = 0; this.curY = 0;
        break;
      case 's': this.savedX = this.curX; this.savedY = this.curY; break;
      case 'u': this.curX = this.savedX; this.curY = this.savedY; break;
      case 'm': this._doSGR(); break;
      case 'n':
        // DSR — Device Status Report. Param 6 = report cursor position as
        // ESC [ <row> ; <col> R (1-based). A program parks the cursor at
        // ESC[999;999H first (clamped to the grid) then reads this back to
        // learn the terminal size. Delivered to the key ring via onReply.
        if (this._P(0, 0) === 6 && this.onReply)
          this.onReply('\x1b[' + (this.curY + 1) + ';' + (this.curX + 1) + 'R');
        break;
    }
  };

  VT100.prototype._doDEC = function (fb) {
    this.wrapNext = false;
    var ch = String.fromCharCode(fb);
    if (ch === 'h') { if (this.params[0] === 25) this.curVis = true; }
    else if (ch === 'l') { if (this.params[0] === 25) this.curVis = false; }
  };

  VT100.prototype._doSGR = function () {
    if (this.paramCount === 0) {
      this.attr.fg = DEF_FG; this.attr.bg = DEF_BG; this.attr.bold = false; this.attr.rev = false;
      return;
    }
    for (var i = 0; i < this.paramCount; i++) {
      var v = this.params[i];
      if (v === 0) { this.attr.fg = DEF_FG; this.attr.bg = DEF_BG; this.attr.bold = false; this.attr.rev = false; }
      else if (v === 1) this.attr.bold = true;
      else if (v === 7) this.attr.rev = true;
      else if (v === 22) this.attr.bold = false;
      else if (v === 27) this.attr.rev = false;
      else if (v >= 30 && v <= 37) this.attr.fg = v - 30;
      else if (v === 39) this.attr.fg = DEF_FG;
      else if (v >= 40 && v <= 47) this.attr.bg = v - 40;
      else if (v === 49) this.attr.bg = DEF_BG;
      else if (v >= 90 && v <= 97) this.attr.fg = (v - 90) + 8;
      else if (v >= 100 && v <= 107) this.attr.bg = v - 100;  // matches desktop (no +8)
    }
  };

  // ---- main byte entry (WriteChar) ---------------------------------------
  VT100.prototype.write = function (ch) {
    ch = ch & 0xFF;
    switch (this.state) {
      case 0: // psNormal
        if (ch === 8) { this.wrapNext = false; this._doBS(); }
        else if (ch === 9) { this.wrapNext = false; this._doTab(); }
        else if (ch === 10) { this.wrapNext = false; this._doCR(); this._doLF(); }
        else if (ch === 13) { this.wrapNext = false; this._doCR(); }
        else if (ch === 27) this.state = 1;
        else if ((ch >= 32 && ch <= 126) || (ch >= 128 && ch <= 255)) {
          // Deferred (DEC pending) wrap: writing the last column parks a
          // pending-wrap instead of advancing; the NEXT printable char does the
          // CR+LF first. CR/LF/cursor moves clear it. So a cols-wide line + CRLF
          // advances ONE row, not two (fixes the immediate-wrap double-spacing).
          if (this.wrapNext) { this._doCR(); this._doLF(); this.wrapNext = false; }
          if (this.curX >= 0 && this.curX < this.cols && this.curY >= 0 && this.curY < this.rows) {
            var cell = this.buf[this._ring(this.curY)][this.curX];
            cell.ch = String.fromCharCode(ch);
            cell.fg = this.attr.fg; cell.bg = this.attr.bg;
            cell.bold = this.attr.bold; cell.rev = this.attr.rev;
          }
          if (this.curX < this.cols - 1) this.curX++;
          else this.wrapNext = true;
        }
        break;
      case 1: // psEsc
        if (ch === 0x5B /* [ */) {
          this.state = 2; this.paramCount = 0; this.paramAccum = 0;
          this.paramSeen = false; this.priv = false;
          for (var i = 0; i < this.params.length; i++) this.params[i] = 0;
        } else if (ch === 0x63 /* c */) this.reset();
        else if (ch === 0x37 /* 7 */) { this.wrapNext = false; this.savedX = this.curX; this.savedY = this.curY; this.state = 0; }
        else if (ch === 0x38 /* 8 */) { this.wrapNext = false; this.curX = this.savedX; this.curY = this.savedY; this.state = 0; }
        else if (ch === 0x4D /* M */) {
          this.wrapNext = false;
          if (this.curY === this.scrollTop) this._scrollDown(this.scrollTop, this.scrollBot);
          else if (this.curY > 0) this.curY--;
          this.state = 0;
        } else this.state = 0;
        break;
      case 2: // psCSI
        if (ch >= 0x30 && ch <= 0x39) { this.paramAccum = this.paramAccum * 10 + (ch - 0x30); this.paramSeen = true; }
        else if (ch === 0x3B /* ; */) {
          if (this.paramCount <= this.params.length - 1) { this.params[this.paramCount] = this.paramAccum; this.paramCount++; }
          this.paramAccum = 0; this.paramSeen = false;
        } else if (ch === 0x3F /* ? */) this.priv = true;
        else {
          if (this.paramSeen || this.paramCount === 0)
            if (this.paramCount <= this.params.length - 1) { this.params[this.paramCount] = this.paramAccum; this.paramCount++; }
          if (this.priv) this._doDEC(ch); else this._doCSI(ch);
          this.state = 0;
        }
        break;
    }
    // xterm sticky scrollback: do NOT snap to live on output. When already at
    // the bottom (viewOffset 0) the view follows new output; when scrolled back
    // it stays put (kept anchored by _scrollUp). The user returns to live by
    // scrolling down to the bottom.
  };

  VT100.prototype.writeString = function (s) {
    for (var i = 0; i < s.length; i++) this.write(s.charCodeAt(i) & 0xFF);
  };
  VT100.prototype.writeBytes = function (arr) {
    for (var i = 0; i < arr.length; i++) this.write(arr[i] & 0xFF);
  };

  // ---- reset --------------------------------------------------------------
  VT100.prototype.reset = function () {
    this.curX = 0; this.curY = 0; this.savedX = 0; this.savedY = 0;
    this.wrapNext = false;
    this.scrollTop = 0; this.scrollBot = Math.max(0, this.rows - 1);
    this.curVis = true; this.viewOffset = 0; this.state = 0;
    this.attr = { fg: DEF_FG, bg: DEF_BG, bold: false, rev: false };
    this.params = new Array(16); for (var i = 0; i < 16; i++) this.params[i] = 0;
    this.paramCount = 0; this.paramAccum = 0; this.paramSeen = false; this.priv = false;
    for (var r = 0; r < this.total; r++) this._blankRingRow(r);
    this.writeRow = this.rows;
  };

  VT100.prototype.resize = function (cols, rows) {     // cols change; clears + reallocs
    this.cols = cols; this.rows = rows; this.maxRows = Math.max(rows, this.maxRows);
    this._alloc(); this.reset();
  };

  // Change the number of VISIBLE rows without clearing. Content is preserved;
  // the top of the screen stays anchored (boot output keeps filling from the
  // top), and scrolled-off lines remain in the scrollback. If the window
  // shrinks below the cursor, the view scrolls down to keep it visible.
  VT100.prototype.setRows = function (n) {
    n = Math.max(1, Math.min(this.maxRows, n | 0));
    if (n === this.rows) return;
    var hist = this.writeRow - this.rows;      // lines scrolled off the top
    this.rows = n;
    this.writeRow = hist + n;                  // keep top anchored; curY unchanged
    if (this.curY > n - 1) { this.writeRow += (this.curY - (n - 1)); this.curY = n - 1; }
    this.savedY = Math.max(0, Math.min(n - 1, this.savedY));
    this.scrollTop = 0; this.scrollBot = n - 1;
    this.viewOffset = 0;
  };

  // ---- read-out (host paint) ---------------------------------------------
  // Live cell (ignores scrollback) — used by the differential test.
  VT100.prototype.liveCellAt = function (visRow, visCol) {
    return this.buf[this._ring(visRow)][visCol];
  };
  // Visible cell honouring scrollback view offset — used by the host painter.
  VT100.prototype.cellAt = function (visRow, visCol) {
    var idx = this.writeRow - this.rows + visRow - this.viewOffset;
    idx = ((idx % this.total) + this.total) % this.total;
    return this.buf[idx][visCol];
  };
  // ---- full-document read-out (native-scroll host) -----------------------
  // The host renders the whole populated document — history-top through the
  // live bottom row — into one scrollable element, and lets the browser own the
  // scroll position. viewOffset is NOT consulted here (the host no longer drives
  // it), so there is a single source of truth for scroll: the DOM scrollTop.
  //   renderRows() = number of renderable lines (history + visible).
  //   histCellAt(i,col), i in [0, renderRows()-1]: i=0 is the oldest history
  //   line, i=renderRows()-1 is the bottom live row.
  VT100.prototype.renderRows = function () { return this.historyDepth() + this.rows; };
  VT100.prototype.histCellAt = function (i, col) {
    var d = this.historyDepth();
    var idx = this.writeRow - this.rows - d + i;     // uniform across history+live
    idx = ((idx % this.total) + this.total) % this.total;
    return this.buf[idx][col];
  };
  VT100.prototype.maxScrollback = function () { return this.total - this.rows; };
  // How many lines above the live window actually hold content (clamps scroll).
  VT100.prototype.historyDepth = function () {
    var off = this.writeRow - this.rows, cap = this.total - this.rows;
    return off < cap ? off : cap;
  };
  VT100.prototype.setViewOffset = function (n) {
    var d = this.historyDepth(); if (n < 0) n = 0; if (n > d) n = d; this.viewOffset = n;
  };

  // ---- differential-test dump --------------------------------------------
  // Plain text of the live visible grid, trailing spaces preserved, plus a
  // cursor/attr footer. Mirror this on the FPC side to diff the two engines.
  VT100.prototype.dump = function () {
    var out = [];
    for (var r = 0; r < this.rows; r++) {
      var s = '';
      for (var c = 0; c < this.cols; c++) s += this.liveCellAt(r, c).ch;
      out.push(s);
    }
    out.push('@cur ' + this.curX + ',' + this.curY + ' vis=' + (this.curVis ? 1 : 0) +
      ' sgr fg=' + this.attr.fg + ' bg=' + this.attr.bg +
      ' b=' + (this.attr.bold ? 1 : 0) + ' r=' + (this.attr.rev ? 1 : 0) +
      ' region=' + this.scrollTop + '-' + this.scrollBot);
    return out.join('\n');
  };
  // Full fidelity: per-cell fg/bg/bold/rev as a parallel grid (for deep diffs).
  VT100.prototype.dumpAttrs = function () {
    var out = [];
    for (var r = 0; r < this.rows; r++) {
      var s = '';
      for (var c = 0; c < this.cols; c++) {
        var x = this.liveCellAt(r, c);
        s += x.fg.toString(16) + x.bg.toString(16) + (x.bold ? 'B' : '.') + (x.rev ? 'R' : '.') + ' ';
      }
      out.push(s);
    }
    return out.join('\n');
  };

  // ---- export -------------------------------------------------------------
  root.VT100 = VT100;
  if (typeof module !== 'undefined' && module.exports) module.exports = VT100;

})(typeof window !== 'undefined' ? window : this);
