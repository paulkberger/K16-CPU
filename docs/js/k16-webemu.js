/* ==================================================================== *
 *  Core — REAL. The K16Core (Part-3 hand-port) wrapped by K16Host,
 *  which presents the same surface the host shell reads
 *  (reset/step/tty/disasm/mem/drawGfx/state/events/loadHex/BASE) and
 *  owns the I/O seam (disk + keyboard + terminal), framebuffer and boot.
 * ==================================================================== */
const Core = new K16Host();

/* ==================================================================== *
 *  Host shell — REAL. Layout/scaling, render loop, transport, panels.
 * ==================================================================== */
const $=id=>document.getElementById(id);
const esc=s=>(s||"").replace(/&/g,"&amp;").replace(/</g,"&lt;");
let running=false, fast=true, gfxActive=false, scaleLabel="1x";
let lastVidMode=-1;   // tracks Core.videoMode to auto-switch term<->gfx on change
let gfxRes="\u2014", gfxScale=1;   // graphics resolution + integer display scale (for status)
// Size the graphics canvas to an integer multiple of the mode's native res that
// fits the wrap, so pixels stay square (matches the old emu's per-mode canvas).
function sizeGfx(){
  const c=$("gfx"), wrap=$("gfxwrap"); if(!c||!wrap) return;
  const mode=(typeof Core!=="undefined"&&Core)?Core.videoMode:0;
  const active = !(mode===0||mode>3);
  // mode 0 / invalid has no live framebuffer, but the canvas STILL needs a pinned
  // CSS size: with none, its display size tracks its own backing store and
  // drawGfx's device resize feeds back into a runaway (white screen, 16M cap).
  // Size it as a 1280x720 reference so it stays a stable black panel.
  const sw = (active && mode!==1)?640:1280, sh = (active && mode!==1)?480:720;
  const ww=wrap.clientWidth||sw, wh=wrap.clientHeight||sh;
  const dpr=window.devicePixelRatio||1;
  const SNAP=2;
  let cssW, cssH;
  if(gfxScaleMode==="fractional"){
    // Fill the pane: binding axis exact, other letterboxed. No wasted space, but
    // pixels are not square at fractional scales.
    const fit=Math.min(ww/sw, wh/sh); cssW=sw*fit; cssH=sh*fit;
  } else if(gfxScaleMode==="device"){
    // Largest integer DEVICE-pixel multiple, then back-compute CSS = backing/dpr
    // so the element's device box equals the backing 1:1. The native->backing
    // upscale is then a whole number -> perfectly even pixels at ANY dpr (the
    // trade is a smaller picture when dpr is high). Falls back to fractional fill
    // if the pane can't hold even 1x of device pixels.
    const kd=Math.min(Math.floor((ww*dpr+SNAP)/sw), Math.floor((wh*dpr+SNAP)/sh));
    if(kd<1){ const fit=Math.min(ww/sw, wh/sh); cssW=sw*fit; cssH=sh*fit; }
    else    { cssW=(sw*kd)/dpr; cssH=(sh*kd)/dpr; }
  } else {
    // "integer" (default): largest integer CSS multiple within SNAP px on BOTH
    // axes. Sharp square pixels; perfectly even only at integer dpr. SNAP rescues
    // the ~1px the .screenwrap borders steal (native 1280 stays 1x, not 0.999x)
    // and snaps 1.998 up to 2x; pixel-based so a genuinely short axis never lifts.
    let k=Math.min(Math.floor((ww+SNAP)/sw), Math.floor((wh+SNAP)/sh));
    if(k<1){ const fit=Math.min(ww/sw, wh/sh); k=fit; }
    cssW=sw*k; cssH=sh*k;
  }
  c.style.width=cssW+"px"; c.style.height=cssH+"px";
  gfxRes = active ? (sw+"\u00d7"+sh) : "\u2014";
  gfxScale = Math.round((cssW/sw)*100)/100;          // actual displayed CSS scale
}
let lastSpeedT=0, frames=0, frameCount=0, memBase=Core.BASE, log=[];
let lastSpeedCyc=0, fastBudget=500000;   // adaptive fast-mode budget (cycles/frame), auto-tuned
let lastFrameTs=0;                        // wall-clock pacing for target-MHz mode
let mhz=10, disUpdate=true, diskLog=false, gfxScaleMode="integer";   // integer | fractional | device
const NW=1280, NH=720;
Core.reset();

/* size 1280x720: 2x if it fits, else 1x floor (never smaller). */
// Advance width of the terminal mono font as a fraction of font-size, measured
// once. Used to size the mobile terminal so all 80 columns fit the viewport.
let _chRatio=0;
function charRatio(){
  if(_chRatio) return _chRatio;
  const p=document.createElement("span");
  p.style.cssText="position:absolute;visibility:hidden;white-space:pre;font-family:var(--mono);font-size:100px;";
  p.textContent="0000000000";
  document.body.appendChild(p);
  _chRatio=(p.getBoundingClientRect().width/10)/100 || 0.6;
  p.remove();
  return _chRatio;
}

function layoutScreen(){
  const main=$("main"), sw=$("screenwrap");
  const insp=document.querySelector(".insp");
  const MOBILE = window.innerWidth <= 820;
  const sideBySide = !MOBILE && window.innerWidth >= 1740;
  main.classList.toggle("stack", !sideBySide);

  if(MOBILE){
    // "Boot and visible" slice: fill the grid cell exactly (border-box, no overflow),
    // size the terminal font so every column fits the width (option B), and fill the
    // height down to the bottom of the viewport for one clean screenful.
    sw.style.width = "100%";
    const availW = sw.clientWidth || (window.innerWidth - 45);
    const cols = (vt?vt.cols:80);
    let tfs = (availW - 12) / (cols * charRatio());             // fill width (minus 6px L/R padding)
    tfs = Math.max(6, Math.min(14, Math.round(tfs*100)/100));   // fractional ok; integer lineH avoids drift
    const lineH = Math.round(tfs*LH);
    const onRef = $("tab-ref").getAttribute("aria-selected")==="true";
    const onIsa = $("tab-isa").getAttribute("aria-selected")==="true";
    if(onRef){
      const top = sw.getBoundingClientRect().top;               // docs want a full-viewport reader
      sw.style.height = Math.max(320, Math.min(window.innerHeight-12,
                          Math.round(window.innerHeight - Math.max(0,top) - 12)))+"px";
    } else if(onIsa){
      sw.style.height = "";                                     // opcode cards flow into the page (no inner scroll)
    } else {
      sw.style.height = (lineH*40 + 28)+"px";                   // cap ~40 rows; inspector follows below
    }
    $("term").style.fontSize = tfs+"px";
    if(insp) insp.style.height = "";
    scaleLabel = "fit";
    alignLegend();
    return;
  }

  const inspReserve = sideBySide ? 396 : 0;
  const availW = window.innerWidth - 32 - 28 - inspReserve;
  let scale = (availW >= NW*2 && window.innerHeight >= NH*2 + 240) ? 2 : 1;
  // Width floored at native 1280 on real desktops, but never wider than the
  // viewport — on tablets (821..1279px, still the non-mobile path) forcing 1280
  // overflowed the page and scrolled the left edge off. Clamp to availW; the gfx
  // canvas scales to fit and the 80-col terminal needs far less than this.
  const w = Math.min(NW*scale, availW), minH = NH*scale;
  let h = minH;
  if(sideBySide){ h = Math.max(minH, window.innerHeight - 176); }  // grow to window height
  // .screenwrap is box-sizing:border-box with a 0.5px border, so style.width=w
  // would give a (w - border) content area — the gfxwrap (width:100%) then lands
  // ~1px under native and the canvas can't sit 1:1. Add the border back, read
  // from the DOM so CSS stays the single source of truth (no hardcoded 1px).
  const bw = Math.max(0, sw.offsetWidth  - sw.clientWidth);   // L+R border px
  const bh = Math.max(0, sw.offsetHeight - sw.clientHeight);  // T+B border px
  sw.style.width = (w+bw)+"px"; sw.style.height = (h+bh)+"px";
  $("term").style.fontSize = (14*scale)+"px";        // constant font; more height = more rows
  if(insp) insp.style.height = sideBySide ? (h+bh)+"px" : "";   // match screenwrap outer height
  scaleLabel = scale>=2 ? "2x" : "1x";
  alignLegend();
}
window.addEventListener("resize", ()=>{ layoutScreen(); renderTerm(); renderDisasm(); sizeGfx(); });

const vt=(typeof VT100!=="undefined") ? new VT100(80,25) : null;  // VT100 engine (host paints it)
window.__vt=vt; let _cw=0;
const LH=17/14;  // line-height ratio: 17px row box at the 14px base font (34px at 2x)
let termDirty=true;   // rebuild the terminal document only when content/rows change

// Drain console bytes from the core and feed the engine. Real Part-2 core
// emits real k/OS console output here; today the stub emits the boot demo.
function pumpTTY(){ if(!vt) return; const b=Core.tty(); if(!b.length) return;
  for(let i=0;i<b.length;i++) vt.write(b[i]); termDirty=true; }

// Map an engine cell (fg/bg byte indices + bold/rev) onto the monochrome
// phosphor scheme. Palette indices collapse to dim / normal / bright shades.
function cellStyle(cell){
  let ink, paper="", w="";
  if(cell.fg===8) ink="var(--tdim)";                       // ESC[90m dim
  else if(cell.bold || cell.fg>=9){ ink="var(--thi)"; w="font-weight:700;"; }  // bold/bright
  else ink="var(--tfg)";                                   // default / normal
  if(cell.bg!==7) paper="var(--tdim)";                     // any non-default bg -> faint block
  if(cell.rev){ ink="var(--term-bg)"; paper="var(--tfg)"; }
  const css="color:"+ink+(paper?(";background:"+paper):"")+";"+w;
  return { css, key:ink+"|"+paper+"|"+w };
}

// Render the terminal as one tall, natively-scrollable document. The grid is
// rebuilt only when the content or visible-row count changed (termDirty); the
// browser owns the scroll position (single source of truth — vt.viewOffset is
// retired from this path). The cursor is a separate overlay repainted every
// frame so blinking never disturbs a live text selection.
function renderTerm(force){
  const el=$("term"); if(!vt){ el.innerHTML=""; return; }
  const availH=el.clientHeight-28;                  // minus .term vertical padding
  if(availH<=0) return;                             // panel collapsed / hidden
  let fs=parseFloat(getComputedStyle(el).fontSize)||14;   // constant size from layoutScreen
  const lineH=Math.round(fs*LH);                    // integer px so rows and cursor share one grid
  const wantRows=Math.max(1, Math.floor(availH/lineH));
  if(wantRows!==vt.rows){ vt.setRows(wantRows); termDirty=true; }
  if(termDirty || force){ buildGrid(el,fs,lineH); termDirty=false; }
  paintCursor(el,lineH);
}

// Build the full populated document (history-top → live bottom) and keep the
// view anchored: pinned-to-bottom follows new output; scrolled-up stays put.
function buildGrid(el,fs,lineH){
  const COLS=vt.cols, total=vt.renderRows();
  const pinned = el.scrollTop + el.clientHeight >= el.scrollHeight - 2;
  const oldH=el.scrollHeight, oldTop=el.scrollTop;
  let html='<div class="tgrid" style="font-size:'+fs+'px;line-height:'+lineH+'px;">';
  for(let i=0;i<total;i++){
    html+='<div class="trow">';
    let c=0;
    while(c<COLS){
      const cell=vt.histCellAt(i,c), st=cellStyle(cell);
      let txt=cell.ch, cc=c+1;
      while(cc<COLS){ const nx=vt.histCellAt(i,cc); if(cellStyle(nx).key!==st.key) break; txt+=nx.ch; cc++; }
      html+='<span style="'+st.css+'">'+esc(txt)+'</span>';
      c=cc;
    }
    html+='</div>';
  }
  html+='<div class="tcur" id="tcur" hidden></div></div>';
  el.innerHTML=html;
  if(pinned) el.scrollTop=el.scrollHeight;                 // follow live
  else       el.scrollTop=oldTop + (el.scrollHeight-oldH); // keep same text in view
}

// Cursor overlay — touches only #tcur, so it never rebuilds the grid (selection
// survives). Blink driven from the clock; focused = solid, unfocused = hollow box.
function paintCursor(el,lineH){
  const cur=$("tcur"); if(!cur) return;
  const _focused=el.classList.contains("tfocus");
  const _blinkOn=!_focused || (Math.floor(performance.now()/550)%2===0);
  if(vt.curVis && _blinkOn){
    const row=vt.historyDepth()+vt.curY;
    cur.textContent=vt.histCellAt(row,vt.curX).ch;
    cur.style.left=vt.curX+"ch";
    cur.style.top=(row*lineH)+"px";
    cur.style.width="1ch";
    cur.style.height=lineH+"px";
    cur.hidden=false;
  } else cur.hidden=true;
}

// ---- terminal clipboard: copy/cut (rtrim) + whole-buffer fallback ----
function termSelectionText(){
  const sel=window.getSelection(); if(!sel || sel.isCollapsed) return "";
  return sel.toString().split("\n").map(l=>l.replace(/[ \t]+$/,"")).join("\n");
}
function termBufferText(){
  if(!vt) return "";
  const n=vt.renderRows(), lines=[];
  for(let i=0;i<n;i++){ let s=""; for(let c=0;c<vt.cols;c++) s+=vt.histCellAt(i,c).ch;
    lines.push(s.replace(/[ \t]+$/,"")); }
  while(lines.length && lines[0]==="") lines.shift();
  while(lines.length && lines[lines.length-1]==="") lines.pop();
  return lines.join("\n");
}
function termCopy(){
  const txt=termSelectionText();
  if(txt && navigator.clipboard) navigator.clipboard.writeText(txt).catch(()=>{});
}
function termCopyAll(){
  const txt=termBufferText();
  if(txt && navigator.clipboard) navigator.clipboard.writeText(txt).catch(()=>{});
}
// Feed host text to k/OS as keystrokes (Paul's paste-block path). CRLF/CR → CR.
function queuePaste(t){
  if(!vt || !t) return;
  t=t.replace(/\r\n?/g,"\n");
  for(const ch of t){ const b=ch.charCodeAt(0); Core.queueKey(b===10?13:(b&0xFF)); }
}
async function termPaste(){
  try{ queuePaste(await navigator.clipboard.readText()); }
  catch(e){ logPush("paste: clipboard read blocked (use Ctrl-V)"); }
}
// Select all terminal text — only the .trow lines, excluding the cursor overlay
// (so no stray glyph), and scoped to the terminal instead of the whole page.
function termSelectAll(){
  const g=$("term").querySelector(".tgrid"); if(!g) return;
  const rows=g.querySelectorAll(".trow"); if(!rows.length) return;
  const sel=window.getSelection(), r=document.createRange();
  r.setStartBefore(rows[0]); r.setEndAfter(rows[rows.length-1]);
  sel.removeAllRanges(); sel.addRange(r);
}

function hex(v,w){ return v.toString(16).toUpperCase().padStart(w,"0"); }
function addr(v){ return hex((v>>16)&0xFF,2)+":"+hex(v&0xFFFF,4); }
function setCell(id,txt){ const el=$(id);
  if(el.textContent!==txt){ el.textContent=txt; el.classList.add("hi");
    setTimeout(()=>el.classList.remove("hi"),180); } }
function alignLegend(){
  const h4=document.querySelector(".card.reg h4"); if(!h4) return;
  const leg=h4.querySelector(".leg"), val=$("r-xy0"); if(!leg||!val) return;
  const vr=val.getBoundingClientRect(), hr=h4.getBoundingClientRect();
  leg.style.left=Math.max(0,(vr.left-hr.left))+"px";
}
function renderRegs(){ const S=Core.state;
  setCell("r-d0",hex(S.D[0],4)); setCell("r-d1",hex(S.D[1],4));
  setCell("r-d2",hex(S.D[2],4)); setCell("r-d3",hex(S.D[3],4));
  setCell("r-xy0",addr(S.XY[0])); setCell("r-xy1",addr(S.XY[1]));
  setCell("r-xy2",addr(S.XY[2])); setCell("r-xy3",addr(S.XY[3])); setCell("r-pc",addr(S.PC));
  document.querySelectorAll("#flags .flag").forEach(f=>f.classList.toggle("on",!!S.SR[f.dataset.f])); }

const DIS_BEFORE=4, DIS_MINFWD=6;   // max greyed history; minimum forward lines
function renderDisasm(){
  const pc=Core.state.PC & 0xFFFFFF;
  let hist=Core.traceRows(DIS_BEFORE).filter(r=>(r.addr&0xFFFFFF)!==pc);
  if(hist.length>DIS_BEFORE) hist=hist.slice(hist.length-DIS_BEFORE);
  // Fit the pane: capacity = rows that fit #disasm's height; forward fills the
  // rest after the history lines. PC floats from the top down to line DIS_BEFORE.
  const el=$("disasm");
  const rowPx=(parseFloat(getComputedStyle(el).fontSize)||11.5)*1.6;
  const cap=Math.max(DIS_BEFORE+DIS_MINFWD, Math.floor((el.clientHeight||260)/rowPx));
  const fwd=Math.max(DIS_MINFWD, cap-hist.length);
  let h="";
  for(const r of hist)
    h+='<div class="dl was"><span class="dgut"> </span>'+
       '<span class="da">'+addr(r.addr&0xFFFFFF)+'</span>  '+
       esc(r.bytes.padEnd(9))+'  <span class="dm">'+esc(r.text)+'</span></div>';
  for(const r of Core.disasm(fwd))
    h+='<div class="dl'+(r.cur?' pc':'')+'"><span class="dgut">'+(r.cur?'\u25B6':' ')+'</span>'+
       '<span class="da">'+addr(r.addr&0xFFFFFF)+'</span>  '+
       esc(r.bytes.padEnd(9))+'  <span class="dm">'+esc(r.text)+'</span></div>';
  $("disasm").innerHTML=h;
  $("dis-pc").textContent=addr(Core.state.PC);
}

function renderMem(){
  const rows=Core.mem(memBase,8,8); let h="";
  for(const r of rows){
    h+='<div><span class="da">'+hex(r.addr,6)+'</span>  '+r.hex+
       '  <span class="as">'+esc(r.ascii)+'</span></div>';
  }
  $("memdump").innerHTML=h; $("mem-addr").textContent=hex(memBase,6);
}

function renderLog(){
  const el=$("log");
  el.innerHTML = log.slice(-200)
    .map(m=>'<div><span class="lt">&raquo;</span> '+esc(m)+'</div>').join("");
  el.scrollTop = el.scrollHeight;   // memo auto-scrolls to newest
}
function logPush(m){ log.push(m); renderLog(); }
function pumpLog(){ const e=Core.drainEvents(); if(e.length){ e.forEach(m=>log.push(m)); renderLog(); } }

function renderStatus(){
  $("s-mode").innerHTML='<span class="dot'+(running?' live':'')+'"></span>'+
    (running?(fast?"fast mode":mhz+" MHz"):"halted");
  const onGfx=$("tab-gfx").getAttribute("aria-selected")==="true";
  const onRef=$("tab-ref").getAttribute("aria-selected")==="true";
  const kbw=$("s-gfxkbwrap"); if(kbw) kbw.hidden=onRef;
  $("s-gfx").textContent = onRef ? ""
    : onGfx ? (lastVidMode===0 ? "no gfx" : gfxRes+(gfxScale>=1 ? " x"+gfxScale : ""))
    : ((vt?vt.cols:80)+"\u00d7"+(vt?vt.rows:25));
  $("s-run").textContent=running?"running":"stopped"; $("s-run").classList.toggle("on",running); }
function tickSpeed(ts){ frames++;
  if(ts-lastSpeedT>=500){
    // Real throughput: measured cycles consumed per wall-second.
    const cyc=Core.state.cycles;
    const cps=running ? (cyc-lastSpeedCyc)/((ts-lastSpeedT)/1000) : 0;
    lastSpeedCyc=cyc;
    $("s-speed").textContent=cps>=1e6?(cps/1e6).toFixed(2)+"M cyc/s":Math.round(cps).toLocaleString()+" cyc/s";
    lastSpeedT=ts; frames=0; } }

const gctx=$("gfx").getContext("2d");
function frame(ts){
  // Real elapsed time since last frame (clamped) — used to pace target-MHz mode
  // so the delivered rate tracks wall-clock regardless of actual frame rate.
  const dt = lastFrameTs ? Math.min((ts-lastFrameTs)/1000, 0.05) : 1/60;
  lastFrameTs = ts;
  if(running){
    let budget;
    if(fast){
      // Adaptive: fill ~11ms of the frame with emulation, leaving the rest for
      // render/input. Measure how long the step takes and re-size for next frame
      // so a fast box runs fast and a slow one (Parallels) stays responsive.
      budget = fastBudget;
      const t0 = performance.now();
      frameCount++; Core.step(budget); Core.requestIRQ();
      const stepMs = Math.max(0.3, performance.now() - t0);
      const want = (budget / stepMs) * 11;                 // cycles that fit in 11ms
      fastBudget = Math.round(fastBudget*0.6 + want*0.4);   // smoothed
      fastBudget = Math.max(60000, Math.min(2000000, fastBudget));   // clamp
    } else {
      budget = Math.max(1, Math.round(mhz*1e6*dt));   // mhz × real seconds elapsed
      frameCount++; Core.step(budget); Core.requestIRQ();
    }
    // Drive lights from real disk-controller activity (bay 0..3 -> C..F).
    for(const ev of Core.drainDiskActivity()){ const L=(typeof ev.bay==="number")?"CDEF"[ev.bay]:ev.bay; if(L) blinkDrive(L, ev.kind==="write"?"write":"read"); }
    // Magic-NOP / breakpoint pause — the core rewinds PC and flags it; stop the
    // run loop so the disassembler shows the stop point (ready for Slow Step).
    if(Core.breakpointHit){
      setRunning(false); refreshAll();
      logPush((Core.magicNopHit?"magic NOP":"breakpoint")+" \u2014 paused at PC="+addr(Core.state.PC));
      tickSpeed(ts); requestAnimationFrame(frame); return;
    }
    // Auto-follow k/OS video mode: 0 = terminal, 1/2/3 = graphics (edge-triggered,
    // so manual tab clicks hold until k/OS next changes the mode; don't yank the
    // Reference tab away from the reader).
    const vm=Core.videoMode;
    if(vm!==lastVidMode){ lastVidMode=vm;
      if($("tab-ref").getAttribute("aria-selected")!=="true") selectTab(vm===0?"term":"gfx");
      sizeGfx(); }
    pumpTTY(); renderTerm(); renderRegs(); if(disUpdate) renderDisasm(); pumpLog();
    if(gfxActive) Core.drawGfx(gctx,ts); renderStatus();
  } else if(gfxActive){ Core.drawGfx(gctx,ts); }
  tickSpeed(ts); requestAnimationFrame(frame);
}

function refreshAll(){ renderRegs(); renderDisasm(); renderMem(); renderTerm(true); renderStatus(); }
function setRunning(on){ running=on; $("b-run").disabled=on; $("b-pause").disabled=!on;
  $("b-step").disabled=on; $("b-anim").disabled=on;   // step/animate are stopped-only tools
  $("b-switch").disabled=!on;                          // shell switch only meaningful while running
  renderStatus(); }

// Single-step. Keyboard is polled and the keyboard-wait is a block/yield, so the
// scheduler needs its timer tick to re-schedule a woken waiter. The run loop
// normally injects that per-frame; while stepping it's stopped, so we deliver a
// timer IRQ every STEPS_PER_TICK manual steps — frequent enough to keep the
// scheduler alive (a queued keystroke can wake the shell) but not every step.
let _stepN=0; const STEPS_PER_TICK=24;
function stepOne(){
  if(running) setRunning(false);
  Core.stepInstruction();
  if(++_stepN>=STEPS_PER_TICK){ _stepN=0; Core.requestIRQ(); }
  pumpTTY(); refreshAll(); pumpLog();
}
$("b-run").onclick=()=>{ stopAnim(); _stepN=0; Core.startDemo(); pumpTTY(); renderTerm(); setRunning(true); pumpLog(); setTimeout(()=>$("term").focus(),0); };
$("b-pause").onclick=()=>{ setRunning(false); refreshAll(); logPush("paused at PC="+addr(Core.state.PC)); };
$("b-step").onclick=()=>{ stopAnim(); stepOne(); };

// ---- Animate: auto-repeat single-step at a watchable rate (slow/med/fast) ----
let animTimer=null, animRate=8;
function stopAnim(){ if(!animTimer) return; clearInterval(animTimer); animTimer=null;
  $("b-anim").classList.remove("on"); $("b-anim").innerHTML="&#9654; animate"; }
function startAnim(){ if(animTimer) return; if(running) setRunning(false);
  $("b-anim").classList.add("on"); $("b-anim").innerHTML="&#9632; stop";
  animTimer=setInterval(()=>{ if(Core.state.halted){ stopAnim(); return; } stepOne(); }, Math.round(1000/animRate)); }
$("b-anim").onclick=()=>{ animTimer ? stopAnim() : startAnim(); };
$("anim-rate").querySelectorAll("button").forEach(b=>b.onclick=()=>{
  animRate=+b.dataset.r;
  $("anim-rate").querySelectorAll("button").forEach(x=>x.classList.toggle("on",x===b));
  if(animTimer){ stopAnim(); startAnim(); } });   // restart at new rate
$("b-load").onclick=()=>$("hex-file").click();
$("hex-file").onchange=(e)=>{ const file=e.target.files[0]; e.target.value=""; if(!file) return;
  const r=new FileReader();
  r.onload=()=>{ const info=Core.loadHex(r.result);
    if(!info.ok || !info.bytes){ logPush("HEX "+file.name+": no valid data records"); pumpLog(); return; }
    const rng="$"+hex((info.minA>>16)&0xFF,2)+":"+hex(info.minA&0xFFFF,4)+"\u2013$"+hex(((info.maxA-1)>>16)&0xFF,2)+":"+hex((info.maxA-1)&0xFFFF,4);
    logPush("loaded "+file.name+" \u2014 "+info.records+" recs, "+info.bytes+" bytes, "+rng+(info.eof?"":"  (no EOF rec)"));
    setRunning(false); Core.reset(); if(vt) vt.reset(); pumpTTY(); memBase=Core.BASE; refreshAll(); pumpLog(); };
  r.readAsText(file); };
$("b-boot").onclick=async ()=>{ stopAnim(); setRunning(false);
  await Core.boot();                                  // re-stage kernel ROM + ROM disk, reset
  if(vt) vt.reset(); memBase=Core.BASE; pumpTTY(); refreshAll(); pumpLog();
  logPush("cold boot - system reloaded"); setRunning(true); setTimeout(()=>$("term").focus(),0); };
$("b-reset").onclick=()=>{ stopAnim(); setRunning(false); Core.reset(); if(vt) vt.reset(); pumpTTY(); memBase=Core.BASE; refreshAll(); pumpLog(); };

function gotoAddr(){
  let v=$("mem-goto").value.trim().replace(/^[#$]/,"").replace(/^0x/i,"");
  const a=parseInt(v,16);
  if(v==="" || isNaN(a)){ logPush("goto: bad address"); return; }
  memBase=(a & 0xFFFFFF) & ~7; renderMem(); logPush("goto "+hex(memBase,6));
}
$("mem-gobtn").onclick=gotoAddr;
$("mem-goto").addEventListener("keydown",e=>{ if(e.key==="Enter") gotoAddr(); });
$("mem-pcbtn").onclick=()=>{ memBase=Core.state.PC & 0xFFFFF8; renderMem(); };

// ---- panel copy buttons (registers / disassembly / memory dump) ----
function panelCopyText(which){
  if(which==="regs"){ const S=Core.state;
    const fl=["C","Z","N","V","I"].map(f=>S.SR[f]?f:"-").join("");
    return ["D0 "+hex(S.D[0],4)+"   XY0 "+addr(S.XY[0]),
            "D1 "+hex(S.D[1],4)+"   XY1 "+addr(S.XY[1]),
            "D2 "+hex(S.D[2],4)+"   XY2 "+addr(S.XY[2]),
            "D3 "+hex(S.D[3],4)+"   XY3 "+addr(S.XY[3]),
            "PC "+addr(S.PC)+"   SR ["+fl+"]"].join("\n");
  }
  if(which==="log") return log.join("\n");
  const id = which==="disasm" ? "disasm" : "memdump";
  return [...$(id).children].map(d=>d.textContent.replace(/\s+$/,"")).join("\n");
}
document.querySelectorAll(".copybtn").forEach(b=>b.onclick=(e)=>{
  e.stopPropagation();
  const txt=panelCopyText(b.dataset.copy);
  if(txt && navigator.clipboard) navigator.clipboard.writeText(txt)
    .then(()=>{ b.classList.add("ok"); clearTimeout(b._t); b._t=setTimeout(()=>b.classList.remove("ok"),900); })
    .catch(()=>{});
});

function selectTab(which){ gfxActive=(which==="gfx");
  $("tab-term").setAttribute("aria-selected",String(which==="term"));
  $("tab-gfx").setAttribute("aria-selected",String(which==="gfx"));
  $("tab-ref").setAttribute("aria-selected",String(which==="ref"));
  $("tab-isa").setAttribute("aria-selected",String(which==="isa"));
  $("term").style.display    = which==="term" ? "block":"none";
  $("gfxwrap").style.display = which==="gfx"  ? "flex":"none";
  $("refwrap").style.display = which==="ref"  ? "flex":"none";
  $("isawrap").style.display = which==="isa"  ? "block":"none";
  if(window.innerWidth<=820) layoutScreen();          // tab-aware screen height on mobile
  if(which==="ref" && !refLoaded) loadDoc(HOME_DOC);
  if(which==="gfx"){ sizeGfx(); const g=$("gfx"); if(g && window.innerWidth>820) setTimeout(()=>g.focus(),0); }
  if(which==="term"){ const t=$("term"); if(t){ renderTerm(true); t.scrollTop=t.scrollHeight; if(window.innerWidth>820) setTimeout(()=>t.focus(),0); } }
  renderStatus(); }
$("tab-term").onclick=()=>selectTab("term");
// ---- Shared key feed: map a DOM keydown to k/OS bytes and queue them. ----
// Single home for the byte mapping; both the terminal handler (after its
// clipboard pre-checks) and the graphics-canvas handler call it.
function feedKeyToCore(e){
  const codes=Core.keyEventToBytes(e);            // exact k/OS key table (incl. shell switch keys)
  if(codes){ for(const b of codes) Core.queueKey(b); e.preventDefault(); e.stopPropagation(); return true; }
  return false;
}

// ---- Keyboard: route keys to the core while the terminal is focused ----
(function(){
  const term=$("term"); if(!term) return;
  term.tabIndex=0;
  term.addEventListener("focus",()=>{ term.classList.add("tfocus"); const t=$("tab-term"); if(t)t.classList.add("kbfocus"); const k=$("s-gfxkb"); if(k)k.classList.add("active"); });
  term.addEventListener("blur", ()=>{ term.classList.remove("tfocus"); const t=$("tab-term"); if(t)t.classList.remove("kbfocus"); const k=$("s-gfxkb"); if(k)k.classList.remove("active"); });
  // grab focus only on a plain click (no selection in progress), so drag-select
  // isn't collapsed.
  term.addEventListener("mouseup",()=>{ if(window.innerWidth>820 && (window.getSelection()+"")==="") setTimeout(()=>term.focus(),0); });

  // Clipboard model "B": bare Ctrl/Cmd keys stay smart so k/OS keeps its control
  // bytes. Ctrl-C copies ONLY when text is selected, else it falls through as
  // 0x03 (break/SIGINT) — the one case that must never be captured. Shift adds an
  // explicit host path that never routes to k/OS.
  term.addEventListener("keydown",e=>{
    const mod=e.ctrlKey||e.metaKey, sh=e.shiftKey, k=e.key.toLowerCase();
    const sel=window.getSelection(), hasSel=!!(sel && !sel.isCollapsed && (sel+"")!=="");
    if(mod){
      if(k==="a"){ termSelectAll(); e.preventDefault(); return; }            // select terminal
      if(k==="c" && sh){ termCopyAll(); e.preventDefault(); return; }        // explicit: whole buffer
      if((k==="c"||k==="x") && hasSel){ termCopy(); e.preventDefault(); return; } // copy/cut selection
      if(k==="v"){                                                          // host paste
        if(sh){ termPaste(); e.preventDefault(); return; }                  // Shift-V: async read
        return;                                                             // bare V: native paste event
      }
      // bare Ctrl-C with no selection (and Ctrl-X) fall through to k/OS below.
    }
    feedKeyToCore(e);
  });
  // Native paste (bare Ctrl/Cmd-V, or OS menu) — no permission prompt.
  term.addEventListener("paste",e=>{
    if(!vt) return; e.preventDefault();
    queuePaste((e.clipboardData||window.clipboardData).getData("text")||"");
  });

  // ---- right-click host-clipboard menu ----
  const menu=$("tmenu");
  function showMenu(x,y){
    const hasSel=(window.getSelection()+"")!=="";
    menu.querySelector('[data-act="copy"]').disabled=!hasSel;
    menu.hidden=false;
    const mw=menu.offsetWidth, mh=menu.offsetHeight;
    menu.style.left=Math.min(x, innerWidth-mw-6)+"px";
    menu.style.top =Math.min(y, innerHeight-mh-6)+"px";
  }
  function hideMenu(){ menu.hidden=true; }
  term.addEventListener("contextmenu",e=>{ e.preventDefault(); showMenu(e.clientX,e.clientY); });
  menu.addEventListener("mousedown",e=>e.preventDefault());  // keep selection/focus
  menu.addEventListener("click",e=>{
    const b=e.target.closest("button"); if(!b) return;
    switch(b.dataset.act){
      case "copy": termCopy(); break;
      case "paste": termPaste(); break;
      case "copyall": termCopyAll(); break;
      case "selectall": termSelectAll(); break;
    }
    hideMenu();
  });
  document.addEventListener("mousedown",e=>{ if(!menu.hidden && !menu.contains(e.target)) hideMenu(); });
  document.addEventListener("keydown",e=>{ if(e.key==="Escape") hideMenu(); });
  term.addEventListener("scroll",hideMenu);
})();

$("tab-gfx").onclick=()=>selectTab("gfx");
$("tab-ref").onclick=()=>selectTab("ref");
$("tab-isa").onclick=()=>selectTab("isa");

// ---- Keyboard: route keys to the core while the GRAPHICS canvas is focused ----
// Mirrors the terminal feed minus all clipboard/selection logic - a graphics app
// wants raw key bytes. Focus is armed by selectTab("gfx") and by clicking the
// surface; the active state tints the Graphics tab label and rings the canvas.
(function(){
  const gfx=$("gfx"), tab=$("tab-gfx"); if(!gfx) return;
  gfx.tabIndex=0;
  gfx.addEventListener("focus",()=>{ if(tab)tab.classList.add("kbfocus"); const k=$("s-gfxkb"); if(k)k.classList.add("active"); });
  gfx.addEventListener("blur", ()=>{ if(tab)tab.classList.remove("kbfocus"); const k=$("s-gfxkb"); if(k)k.classList.remove("active"); });
  gfx.addEventListener("mousedown",()=>{ if(window.innerWidth>820) setTimeout(()=>gfx.focus(),0); });
  gfx.addEventListener("keydown",e=>feedKeyToCore(e));
})();

// Clicking the status-bar keyboard icon re-arms input on the current surface.
(function(){
  const kb=$("s-gfxkb"); if(!kb) return;
  kb.addEventListener("mousedown",e=>{
    e.preventDefault();                                  // don't let the click blur first
    const onGfx=$("tab-gfx").getAttribute("aria-selected")==="true";
    const el=$(onGfx?"gfx":"term"); if(el) el.focus();
  });
  // Debug aid: refresh the focus hint with the canvas's live on-screen size,
  // but only as the pointer arrives (the tip is a hover-only ::after — no point
  // rewriting it every frame). gfxwrap is display:none off-tab, so clientW/H
  // are only meaningful on the Gfx tab.
  const kbw=$("s-gfxkbwrap");
  if(kbw) kbw.addEventListener("pointerenter",()=>{
    const FOCUS="Focus keyboard input";
    const FOOT="\n"+"\u2500".repeat(22)+"\n"+FOCUS;     // divider + label under the debug lines
    const onGfx=$("tab-gfx").getAttribute("aria-selected")==="true";
    if(!onGfx){ kbw.setAttribute("data-tip",FOCUS); return; }
    const g=$("gfx"), w=$("gfxwrap");
    const gr=g?g.getBoundingClientRect():null, wr=w?w.getBoundingClientRect():null;
    const cw=gr?Math.round(gr.width*100)/100:0, ch=gr?Math.round(gr.height*100)/100:0;
    const mode=(typeof Core!=="undefined"&&Core)?Core.videoMode:0;
    // No active gfx mode: sizeGfx left the canvas at its intrinsic buffer size,
    // so a fit calc would be meaningless. Say so rather than invent ratios.
    if(mode===0||mode>3){
      kbw.setAttribute("data-tip","canvas "+cw+"\u00d7"+ch+" \u00b7 no active gfx mode (vid="+mode+")"+FOOT);
      return;
    }
    // Show the ACTUAL displayed scale (measured), plus the device-pixel scale,
    // plus the active mode — accurate for all three scale modes.
    const sw=mode===1?1280:640, sh=mode===1?720:480;
    const ww=wr?wr.width:0, wh=wr?wr.height:0;
    const fx=sw?ww/sw:0, fy=sh?wh/sh:0;
    const r1=v=>Math.round(v*10)/10, r3=v=>Math.round(v*1000)/1000;
    const dpr=window.devicePixelRatio||1;
    const cssK=sw?cw/sw:0, devK=sw?(cw*dpr)/sw:0;
    kbw.setAttribute("data-tip",
      "canvas "+cw+"\u00d7"+ch+" \u00b7 native "+sw+"\u00d7"+sh+"\n"+
      "wrap "+r1(ww)+"\u00d7"+r1(wh)+" \u00b7 fit W"+r3(fx)+"/H"+r3(fy)+"\n"+
      "scale \u00d7"+r3(cssK)+" css / \u00d7"+r3(devK)+" dev \u00b7 "+gfxScaleMode+"\n"+
      "dpr "+r3(dpr)+" \u2192 dev "+Math.round(cw*dpr)+"\u00d7"+Math.round(ch*dpr)+FOOT);
  });
})();

// ---- Mobile keyboard + task switching ----------------------------------
// iOS only raises the soft keyboard for a real editable element, and its soft
// keys deliver printables through beforeinput (keydown reports Unidentified /
// keyCode 229 during predictive entry) - so on mobile we route input through a
// hidden proxy <textarea>, not the term/gfx keydown path. Desktop (>820) never
// touches this: the proxy is never focused and the existing handlers stand.
(function(){
  const proxy=$("kbproxy"); if(!proxy) return;
  const MOB=()=>window.innerWidth<=820;

  // Focus the proxy (raising the keyboard) and mirror the on-screen focus ring
  // onto whichever surface is active, so the cursor still goes solid.
  function focusProxy(){
    proxy.value="";
    proxy.focus();
  }
  function ringOn(){
    const onGfx=$("tab-gfx").getAttribute("aria-selected")==="true";
    if(onGfx){ const t=$("tab-gfx"); if(t)t.classList.add("kbfocus"); }
    else{ $("term").classList.add("tfocus"); const t=$("tab-term"); if(t)t.classList.add("kbfocus"); }
    const k=$("s-gfxkb"); if(k)k.classList.add("active");
  }
  function ringOff(){
    $("term").classList.remove("tfocus");
    const tt=$("tab-term"); if(tt)tt.classList.remove("kbfocus");
    const tg=$("tab-gfx");  if(tg)tg.classList.remove("kbfocus");
    const k=$("s-gfxkb"); if(k)k.classList.remove("active");
  }
  proxy.addEventListener("focus",ringOn);
  proxy.addEventListener("blur",ringOff);

  // Tapping the term or gfx surface routes focus to the proxy on mobile, within
  // the tap gesture iOS needs to raise the keyboard. The surfaces' own self-focus
  // (term mouseup / gfx mousedown) is gated to desktop so it can't steal focus
  // back from the proxy on a deferred timer and drop the keyboard.
  ["term","gfx"].forEach(id=>{
    const el=$(id); if(!el) return;
    el.addEventListener("click",()=>{ if(MOB()) focusProxy(); });
  });
  // The status-bar keyboard icon: re-arm input within a real touch gesture.
  const kbw=$("s-gfxkbwrap");
  if(kbw) kbw.addEventListener("touchend",e=>{ if(MOB()){ e.preventDefault(); focusProxy(); } },{passive:false});

  // keydown: control keys + Ctrl-combos only. Bare printables AND Enter/Backspace
  // are left to beforeinput, so soft and external keyboards both emit once.
  proxy.addEventListener("keydown",e=>{
    const k=e.key;
    if(k==="Enter"||k==="Backspace") return;                 // -> beforeinput
    if(!e.ctrlKey&&!e.metaKey&&!e.altKey&&k.length===1) return; // printable -> beforeinput
    feedKeyToCore(e);                                          // arrows/Tab/Esc/Ctrl-*
  });

  // beforeinput: the printable + edit path. Cancel it (nothing should land in
  // the textarea) so the value stays empty; the input fallback below only fires
  // when beforeinput wasn't cancelable (older iOS predictive paths).
  proxy.addEventListener("beforeinput",e=>{
    const t=e.inputType;
    if(t==="insertLineBreak"||t==="insertParagraph"){ Core.queueKey(13); if(e.cancelable)e.preventDefault(); return; }
    if(t==="deleteContentBackward"){ Core.queueKey(8); if(e.cancelable)e.preventDefault(); return; }
    if(t==="insertText"||t==="insertCompositionText"||t==="insertReplacementText"){
      const s=e.data||"";
      for(const ch of s){ const c=ch.charCodeAt(0); if(c>=32&&c<=126) Core.queueKey(c); }
      if(e.cancelable)e.preventDefault();
    }
  });
  // Fallback for non-cancelable beforeinput: read what landed, queue it, clear.
  proxy.addEventListener("input",()=>{
    const s=proxy.value; if(!s) return;
    for(const ch of s){ const c=ch.charCodeAt(0);
      if(c===10||c===13) Core.queueKey(13);
      else if(c>=32&&c<=126) Core.queueKey(c); }
    proxy.value="";
  });

  // Next-shell switcher (k/OS $0E, cycles + wraps). mousedown+preventDefault
  // keeps the proxy focused so the keyboard doesn't drop on tap (mobile); on
  // desktop it just suppresses focus-steal, harmless. The button is gated by
  // setRunning, so it only fires while the CPU is running.
  const nx=$("b-switch");
  if(nx) nx.addEventListener("mousedown",e=>{ e.preventDefault(); Core.queueKey(0x0E); });
})();

/* ---- Reference tab: Docs_Home hub + in-panel .md navigation ---- */
const REPO_RAW_BASE="https://raw.githubusercontent.com/paulkberger/K16-CPU/main/";
const REPO_BLOB_BASE="https://github.com/paulkberger/K16-CPU/blob/main/";
const HOME_DOC="Docs_Home.md";
let currentDoc=null, refLoaded=false;

/* classify a link: repo .md -> {doc,anchor} for in-panel nav, else null */
function parseDocLink(href){
  let h=href, anchor="";
  const hash=h.indexOf("#"); if(hash>=0){ anchor=h.slice(hash+1); h=h.slice(0,hash); }
  h=h.replace(/^https?:\/\/github\.com\/paulkberger\/K16-CPU\/(blob|raw)\/[^/]+\//i,"");
  h=h.replace(/^https?:\/\/raw\.githubusercontent\.com\/paulkberger\/K16-CPU\/[^/]+\//i,"");
  if(/^https?:\/\//i.test(h)) return null;        // some other absolute URL
  h=h.replace(/^\.?\//,"");                        // drop leading ./ or /
  if(!/\.md$/i.test(h) || /(^|\/)\.\.(?=\/|$)/.test(h)) return null;  // repo .md, subdirs ok, block ..
  return { doc:h, anchor:anchor };
}

function mdToHtml(src){
  src=src.replace(/\r\n/g,"\n");
  const esc=s=>s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
  const fences=[];
  src=src.replace(/```[^\n]*\n([\s\S]*?)```/g,(m,code)=>{
    fences.push("<pre><code>"+esc(code.replace(/\n$/,""))+"</code></pre>");
    return "\n\u0000"+(fences.length-1)+"\u0000\n"; });
  const inline=t=>{ t=esc(t);
    t=t.replace(/\[((?:[^\[\]]|\[[^\]]*\])*)\]\(([^) ]+)\)/g,(m,x,href)=>{
      if(href.charAt(0)==="#") return '<a href="'+href+'" class="ref-int">'+x+'</a>';
      const d=parseDocLink(href);
      if(d) return '<a href="#" class="ref-doc" data-doc="'+encodeURIComponent(d.doc)+'" data-anchor="'+encodeURIComponent(d.anchor)+'">'+x+'</a>';
      return '<a href="'+href+'" target="_blank" rel="noopener">'+x+'</a>'; });
    t=t.replace(/`([^`]+)`/g,"<code>$1</code>");
    t=t.replace(/\*\*([^*]+)\*\*/g,"<strong>$1</strong>");
    t=t.replace(/\*([^*\n]+)\*/g,"<em>$1</em>");
    return t; };
  const slug=raw=>{ let id=raw.replace(/`/g,"").replace(/\*/g,"").replace(/\[([^\]]+)\]\([^)]*\)/g,"$1")
      .toLowerCase().replace(/[^\w\s-]/g,"").trim().replace(/\s/g,"-");
    if(seen[id]!==undefined){ seen[id]++; id+="-"+seen[id]; } else seen[id]=0; return id; };
  const isSep=s=>/^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$/.test(s);
  const stripPipes=c=>{ if(c.length&&c[0]==="") c.shift(); if(c.length&&c[c.length-1]==="") c.pop(); return c; };
  const lines=src.split("\n"); let html="", i=0, seen={};
  while(i<lines.length){ let ln=lines[i];
    let fm=ln.match(/^\u0000(\d+)\u0000$/); if(fm){ html+=fences[+fm[1]]; i++; continue; }
    if(/^\s*$/.test(ln)){ i++; continue; }
    let h=ln.match(/^(#{1,6})\s+(.*)$/); if(h){ const lv=h[1].length;
      html+="<h"+lv+' id="'+slug(h[2])+'">'+inline(h[2])+"</h"+lv+">"; i++; continue; }
    if(/^\s*([-*_])\1{2,}\s*$/.test(ln)){ html+="<hr>"; i++; continue; }
    if(ln.indexOf("|")>=0 && i+1<lines.length && isSep(lines[i+1])){
      const head=stripPipes(ln.split("|").map(c=>c.trim()));
      let t="<table><thead><tr>"+head.map(c=>"<th>"+inline(c)+"</th>").join("")+"</tr></thead><tbody>"; i+=2;
      while(i<lines.length && lines[i].indexOf("|")>=0 && !/^\s*$/.test(lines[i])){
        const cells=stripPipes(lines[i].split("|").map(c=>c.trim()));
        t+="<tr>"+cells.map(c=>"<td>"+inline(c)+"</td>").join("")+"</tr>"; i++; }
      html+=t+"</tbody></table>"; continue; }
    if(/^\s*>/.test(ln)){ let q=[]; while(i<lines.length && /^\s*>/.test(lines[i])){ q.push(lines[i].replace(/^\s*>\s?/,"")); i++; } html+="<blockquote>"+inline(q.join(" "))+"</blockquote>"; continue; }
    if(/^\s*[-*+]\s+/.test(ln) || /^\s*\d+\.\s+/.test(ln)){
      const ord=/^\s*\d+\.\s+/.test(ln), tag=ord?"ol":"ul";
      const mk=z=> ord?/^\s*\d+\.\s+/.test(z):/^\s*[-*+]\s+/.test(z);
      const anyMk=z=> /^\s*[-*+]\s+/.test(z) || /^\s*\d+\.\s+/.test(z);
      const items=[]; let cur=null;
      while(i<lines.length){ const L=lines[i];
        if(/^\s*$/.test(L)){ let j=i+1; while(j<lines.length && /^\s*$/.test(lines[j])) j++;
          if(j<lines.length && mk(lines[j])){ i=j; continue; } else break; }
        if(mk(L)){ if(cur!==null) items.push(cur); cur=L.replace(/^\s*(?:\d+\.|[-*+])\s+/,""); i++; }
        else if(anyMk(L)){ break; }
        else { if(cur!==null){ cur+=" "+L.trim(); i++; } else break; } }
      if(cur!==null) items.push(cur);
      html+="<"+tag+">"+items.map(x=>"<li>"+inline(x)+"</li>").join("")+"</"+tag+">"; continue; }
    let p=[ln]; i++;
    while(i<lines.length && !/^\s*$/.test(lines[i]) && !/^(#{1,6})\s/.test(lines[i]) && !/^\s*[-*+]\s/.test(lines[i]) && !/^\s*\d+\.\s/.test(lines[i]) && !/^\s*>/.test(lines[i]) && !/^\u0000\d+\u0000$/.test(lines[i]) && !(lines[i].indexOf("|")>=0 && i+1<lines.length && isSep(lines[i+1]))){ p.push(lines[i]); i++; }
    html+="<p>"+inline(p.join(" "))+"</p>"; }
  return html;
}
function refScrollTo(el, mode){
  if(!el) return;
  const box=$("ref-content");
  const cr=box.getBoundingClientRect(), br=el.getBoundingClientRect();
  let top = box.scrollTop + (br.top - cr.top);
  if(mode==="center") top += -box.clientHeight/2 + br.height/2; else top -= 8;
  box.scrollTo({ top:Math.max(0, top), behavior:"smooth" });   // container only — leaves .screenwrap put
}
function refScrollAnchor(anchor){ if(!anchor) return; const box=$("ref-content");
  refScrollTo(box.querySelector("#"+(window.CSS&&CSS.escape?CSS.escape(anchor):anchor))); }
function refWireLinks(box){
  box.querySelectorAll("a.ref-int").forEach(a=>a.onclick=ev=>{ ev.preventDefault();
    refScrollAnchor(decodeURIComponent((a.getAttribute("href")||"").slice(1))); });
  box.querySelectorAll("a.ref-doc").forEach(a=>a.onclick=ev=>{ ev.preventDefault();
    loadDoc(decodeURIComponent(a.dataset.doc), decodeURIComponent(a.dataset.anchor||""), true); });
}
let history=[], histIdx=-1, scrollMem={}, refStats={lines:0,words:0};
function saveScroll(){ if(currentDoc) scrollMem[currentDoc]=$("ref-content").scrollTop; }
function updateNavButtons(){ $("ref-back").disabled=histIdx<=0; $("ref-fwd").disabled=histIdx>=history.length-1; }
async function renderDoc(name){
  const box=$("ref-content"); box.innerHTML='<div class="ref-loading">Loading&hellip;</div>';
  try{ const r=await fetch(REPO_RAW_BASE+name,{cache:"no-cache"}); if(!r.ok) throw new Error("HTTP "+r.status);
    const md=await r.text(); box.innerHTML=mdToHtml(md);
    refStats.lines=md.split(/\r\n|\r|\n/).length;
    refStats.words=(box.textContent.trim().match(/\S+/g)||[]).length;
    currentDoc=name; refLoaded=true;
    const tEl=$("ref-title"); if(tEl){ const h1=box.querySelector("h1"); tEl.textContent=h1?h1.textContent:name.replace(/\.md$/i,""); }
    $("ref-gh").href=REPO_BLOB_BASE+name; $("ref-home").hidden=(name===HOME_DOC);
    refWireLinks(box); buildTOC(); $("ref-toc").hidden=true; clearFind(false); return true;
  }catch(e){ box.innerHTML='<div class="ref-err">Couldn\'t load '+name+' ('+(e.message||e)+').<br>Serve over http/https \u2014 a file:// page can\'t fetch it.<br><br><a href="'+REPO_BLOB_BASE+name+'" target="_blank" rel="noopener">Open on GitHub \u2197</a></div>';
    currentDoc=name; refLoaded=true; return false; }
}
async function loadDoc(name, anchor){
  name=name||HOME_DOC;
  if(name===currentDoc && refLoaded){ $("ref-content").scrollTop=0; if(anchor) setTimeout(()=>refScrollAnchor(anchor),0); return; }
  saveScroll();
  const ok=await renderDoc(name);
  history=history.slice(0,histIdx+1); history.push({doc:name}); histIdx=history.length-1; updateNavButtons();
  $("ref-content").scrollTop=0;
  if(ok && anchor) setTimeout(()=>refScrollAnchor(anchor),0);
}
async function navTo(idx){ if(idx<0||idx>=history.length) return; saveScroll(); histIdx=idx;
  const e=history[histIdx]; const ok=await renderDoc(e.doc); updateNavButtons();
  $("ref-content").scrollTop = ok ? (scrollMem[e.doc]||0) : 0; }
$("ref-back").onclick=()=>navTo(histIdx-1);
$("ref-fwd").onclick=()=>navTo(histIdx+1);
$("ref-home").onclick=()=>loadDoc(HOME_DOC);
$("ref-reload").onclick=async ()=>{ const sc=$("ref-content").scrollTop; const ok=await renderDoc(currentDoc); if(ok) $("ref-content").scrollTop=sc; };
$("ref-content").addEventListener("scroll",()=>{ $("ref-top").hidden=$("ref-content").scrollTop<260; });
$("ref-top").onclick=()=>$("ref-content").scrollTo({top:0,behavior:"smooth"});
function buildTOC(){ const box=$("ref-content"), toc=$("ref-toc");
  const hs=[...box.querySelectorAll("h2, h3, h4")];
  const mins=Math.max(1,Math.round(refStats.words/220));
  const stat='<div class="ref-toc-stat">'+hs.length+' sections \u00b7 '+refStats.lines.toLocaleString()+' lines \u00b7 '+refStats.words.toLocaleString()+' words \u00b7 ~'+mins+' min read</div>';
  if(!hs.length){ toc.innerHTML=stat+'<div class="ref-toc-empty">No sections</div>'; return; }
  toc.innerHTML=stat+hs.map(h=>'<a class="'+(h.tagName==="H2"?"lvl1":h.tagName==="H3"?"lvl2":"lvl3")+'" data-id="'+h.id+'">'+h.textContent+'</a>').join("");
  toc.querySelectorAll("a").forEach(a=>a.onclick=ev=>{ ev.preventDefault(); toc.hidden=true; refScrollAnchor(a.dataset.id); }); }
$("ref-toc-btn").onclick=(e)=>{ e.stopPropagation(); const t=$("ref-toc"); t.hidden=!t.hidden; };
$("ref-toc").addEventListener("click",e=>e.stopPropagation());
document.addEventListener("click",()=>{ const t=$("ref-toc"); if(t&&!t.hidden) t.hidden=true; });

/* ---- Reference: find-in-page (current doc only; no fetch, no index) ---- */
let findHits=[], findCur=-1, findTimer=null;
function clearFind(keepQuery){
  const box=$("ref-content");
  box.querySelectorAll("mark.refhit").forEach(m=>m.replaceWith(document.createTextNode(m.textContent)));
  box.normalize();
  findHits=[]; findCur=-1;
  $("ref-find-prev").disabled=$("ref-find-next").disabled=true;
  $("ref-find-n").textContent="";
  if(!keepQuery){ const f=$("ref-find"); if(f) f.value=""; const x=$("ref-find-clear"); if(x) x.hidden=true; }
}
function runFind(){
  const q=$("ref-find").value;
  clearFind(true);
  if(q.length<2) return;                       // need >=2 chars; 1-char hits are noise
  const box=$("ref-content"), needle=q.toLowerCase();
  const walker=document.createTreeWalker(box, NodeFilter.SHOW_TEXT, {
    acceptNode(n){ const p=n.parentNode;
      if(p && (p.tagName==="SCRIPT"||p.tagName==="STYLE")) return NodeFilter.FILTER_REJECT;
      return n.nodeValue.toLowerCase().includes(needle) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; } });
  const targets=[]; let n; while((n=walker.nextNode())) targets.push(n);
  targets.forEach(node=>{
    const text=node.nodeValue, low=text.toLowerCase();
    const frag=document.createDocumentFragment(); let i=0, idx, last=0;
    while((idx=low.indexOf(needle,i))!==-1){
      if(idx>last) frag.appendChild(document.createTextNode(text.slice(last,idx)));
      const mk=document.createElement("mark"); mk.className="refhit"; mk.textContent=text.slice(idx,idx+needle.length);
      frag.appendChild(mk); last=idx+needle.length; i=last;
    }
    if(last<text.length) frag.appendChild(document.createTextNode(text.slice(last)));
    node.parentNode.replaceChild(frag,node);
  });
  findHits=[...box.querySelectorAll("mark.refhit")];
  if(findHits.length){
    $("ref-find-prev").disabled=$("ref-find-next").disabled=false;
    const top=box.getBoundingClientRect().top;                 // viewport top of the scroll box
    let start=findHits.findIndex(el=>el.getBoundingClientRect().top >= top-1);
    if(start<0) start=0;                                        // none below the fold → wrap to first
    stepFind(0,true,start);
  }
  else { $("ref-find-n").textContent="0/0"; }
}
function stepFind(dir,absolute,toIndex){
  if(!findHits.length) return;
  if(findCur>=0 && findHits[findCur]) findHits[findCur].classList.remove("refcur");
  findCur = absolute ? (typeof toIndex==="number" ? toIndex : 0) : (findCur+dir+findHits.length)%findHits.length;
  const el=findHits[findCur]; el.classList.add("refcur");
  refScrollTo(el,"center");
  $("ref-find-n").textContent=(findCur+1)+"/"+findHits.length;
}
$("ref-find").addEventListener("input",()=>{ $("ref-find-clear").hidden=!$("ref-find").value;
  clearTimeout(findTimer); findTimer=setTimeout(runFind,160); });
$("ref-find").addEventListener("keydown",e=>{
  if(e.key==="Enter"){ e.preventDefault(); stepFind(e.shiftKey?-1:1); }
  else if(e.key==="Escape"){ e.preventDefault(); clearFind(false); $("ref-find").blur(); } });
$("ref-find-clear").onclick=()=>{ clearFind(false); $("ref-find").focus(); };
$("ref-find-prev").onclick=()=>stepFind(-1);
$("ref-find-next").onclick=()=>stepFind(1);


const TERM={
  green:{bg:"#0b1410",fg:"#4ee08a",dim:"#2e9d63",hi:"#79f2a6",glow:"0 0 3px rgba(78,224,138,.4)",flat:false,
         head:"#1d9e75",hbg:"rgba(29,158,117,.15)",hbd:"rgba(29,158,117,.42)",ctl:"#1d9e75",
         sbThumb:"#9cc7b0",sbHover:"#4ee08a",sbTrack:"rgba(255,255,255,.05)"},
  amber:{bg:"#160f04",fg:"#ffb000",dim:"#b37b00",hi:"#ffd166",glow:"0 0 3px rgba(255,176,0,.4)",flat:false,
         head:"#b5730a",hbg:"rgba(181,115,10,.16)",hbd:"rgba(181,115,10,.42)",ctl:"#c2740f",
         sbThumb:"#e0c48f",sbHover:"#ffb000",sbTrack:"rgba(255,255,255,.05)"},
  white:{bg:"#000000",fg:"#e6e6e6",dim:"#8a8a8a",hi:"#ffffff",glow:"none",flat:true,
         head:"#5790c2",hbg:"rgba(87,144,194,.16)",hbd:"rgba(87,144,194,.42)",ctl:"#3b82f6",
         sbThumb:"#707070",sbHover:"#a0a0a0",sbTrack:"rgba(255,255,255,.05)"},
  paper:{bg:"#f2f2ea",fg:"#1a1a18",dim:"#6b6b66",hi:"#000000",glow:"none",flat:true,
         head:"#4c83b8",hbg:"rgba(76,131,184,.16)",hbd:"rgba(76,131,184,.42)",ctl:"#2f6fd0",
         sbThumb:"rgba(20,20,16,.22)",sbHover:"#6b6b66",sbTrack:"transparent"}
};
function setTermTheme(n){ const t=TERM[n]||TERM.green; const r=document.querySelector(".machine").style;
  r.setProperty("--tbg",t.bg); r.setProperty("--tfg",t.fg); r.setProperty("--tdim",t.dim);
  r.setProperty("--thi",t.hi); r.setProperty("--tglow",t.glow);
  r.setProperty("--head",t.head); r.setProperty("--headbg",t.hbg); r.setProperty("--headbord",t.hbd);
  r.setProperty("--sbt-thumb",t.sbThumb); r.setProperty("--sbt-hover",t.sbHover); r.setProperty("--sbt-track",t.sbTrack);
  r.setProperty("--ctl",t.ctl); $("term").classList.toggle("flat",t.flat); }
$("set-term").onchange=e=>{ setTermTheme(e.target.value); saveIni(); };

function setSpeedMode(f){ fast=f;
  $("spd-fast").classList.toggle("on",f); $("spd-mhz").classList.toggle("on",!f);
  $("spd-val").disabled=f; renderStatus(); }
$("spd-fast").onclick=()=>{ setSpeedMode(true); saveIni(); };
$("spd-mhz").onclick=()=>{ setSpeedMode(false); saveIni(); };
$("spd-val").addEventListener("change",e=>{ mhz=Math.max(1,Math.min(50,parseInt(e.target.value)||10)); e.target.value=mhz; renderStatus(); saveIni(); });

$("set-disupd").onchange=e=>{ disUpdate=e.target.checked; Core.setTrace(disUpdate); if(disUpdate) renderDisasm(); saveIni(); };
$("set-disklog").onchange=e=>{ diskLog=e.target.checked; logPush("disk logging "+(diskLog?"on":"off")); saveIni(); };
$("set-gfxscale").onchange=e=>{ gfxScaleMode=e.target.value; sizeGfx(); renderStatus(); saveIni(); };

$("b-gear").onclick=(e)=>{ e.stopPropagation(); closeDrives(); closeFiles(); const p=$("settings-pop");
  p.hidden=!p.hidden; $("b-gear").classList.toggle("active",!p.hidden); };
document.addEventListener("click",(e)=>{ const p=$("settings-pop");
  if(!p.hidden && !p.contains(e.target) && !e.target.closest("#b-gear")){
    p.hidden=true; $("b-gear").classList.remove("active"); } });

/* ---- Host files: OPFS uploads/ folder; k/OS LOAD reads these (core hook) ---- */
let uploads=[]; let selFile=null; let persistOK=false; let linkedDir=null; let pendingDir=null;
async function checkPersist(){ try{ const root=await navigator.storage.getDirectory();
  await root.getFileHandle("__probe",{create:true}); await root.removeEntry("__probe"); return true;
  }catch(e){ return false; } }
function applyPersistUI(){
  const fn=$("files-pnote"); if(fn) fn.hidden = persistOK || !!linkedDir;
  const dn=$("drives-pnote"); if(dn) dn.hidden = persistOK || !!diskLinkedDir;
  const sn=$("settings-pnote"); if(sn) sn.hidden = persistOK;
}
function fmtBytes(n){ return n>=1048576 ? (n/1048576).toFixed(1)+" MB" : n>=1024 ? (n/1024).toFixed(1)+" KB" : n+" B"; }
function fileKind(name){ const e=(name.split(".").pop()||"").toLowerCase();
  if(["com","bin","exe"].includes(e)) return "#1d9e75";
  if(["asm","inc","s"].includes(e)) return "#3b82f6";
  if(["pas","p","pp"].includes(e)) return "#8b5cf6";
  if(["txt","md","ini","cfg","lst"].includes(e)) return "#8a93a6";
  return "#8a93a6"; }
function fileIcon(name){ const c=fileKind(name);
  return '<svg class="fi" viewBox="0 0 24 24" fill="none" stroke="'+c+'" stroke-width="1.6">'+
    '<path d="M6 2.5h7.5L18 7v14.5H6z"/><path d="M13.5 2.5V7H18"/></svg>'; }
function renderFiles(){
  const list=$("fx-list");
  $("fx-count").textContent=uploads.length+(uploads.length===1?" item":" items");
  if(!uploads.length){
    list.innerHTML='<div class="fx-empty"><span>Drop files here</span><span style="font-size:11px">or use Add files\u2026</span></div>';
  } else {
    list.innerHTML=uploads.slice().sort((a,b)=>a.name.localeCompare(b.name)).map(fl=>
      '<div class="fx-row'+(selFile===fl.name?" sel":"")+'" data-name="'+fl.name+'">'+
      fileIcon(fl.name)+'<span class="fx-name">'+fl.name+'</span>'+
      '<span class="fx-size">'+fmtBytes(fl.size)+'</span></div>').join("");
    list.querySelectorAll(".fx-row").forEach(r=>{
      r.onclick=()=>{ selFile=r.dataset.name; renderFiles(); };
      r.ondblclick=()=>{ selectTab("term"); queuePaste("load "+r.dataset.name+"\n"); };
    });
  }
  const rm=$("fx-remove"); if(rm) rm.disabled=!(selFile && uploads.find(u=>u.name===selFile));
}
/* Mirror the uploads/ folder into the host so kosh `load` (HOST_CMD_FOPEN/
   FREAD/FCLOSE) can read it. Shares the byte arrays; called after every
   uploads[] mutation. */
function syncLoadFiles(){ Core.loadFilesSet(uploads.map(u=>({name:u.name,data:u.bytes}))); }

function addUploads(fileList){
  let pending=fileList.length; if(!pending) return;
  Array.from(fileList).forEach(file=>{
    const r=new FileReader();
    r.onload=()=>{ const bytes=new Uint8Array(r.result);
      const ex=uploads.find(u=>u.name===file.name);
      if(ex){ ex.size=bytes.length; ex.bytes=bytes; } else uploads.push({name:file.name,size:bytes.length,bytes});
      saveUpload(file.name,bytes); logPush("uploaded "+file.name+" ("+fmtBytes(bytes.length)+")");
      if(--pending===0){ syncLoadFiles(); renderFiles(); } };
    r.readAsArrayBuffer(file);
  });
}
function removeFile(name){ uploads=uploads.filter(u=>u.name!==name); if(selFile===name) selFile=null;
  deleteUpload(name); syncLoadFiles(); logPush("removed "+name); renderFiles(); }

async function activeDir(create){
  if(linkedDir) return linkedDir;
  const root=await navigator.storage.getDirectory();
  return await root.getDirectoryHandle("uploads",{create:!!create}); }
async function saveUpload(name,bytes){ try{ const d=await activeDir(true);
  const fh=await d.getFileHandle(name,{create:true}); const w=await fh.createWritable();
  await w.write(bytes); await w.close(); }catch(e){ logPush("save failed: "+name); } }
async function deleteUpload(name){ try{ const d=await activeDir(false); await d.removeEntry(name); }catch(e){} }
async function loadUploads(){ try{ const d=await activeDir(false); uploads=[];
  for await (const [n,h] of d.entries()){ if(h.kind==="file"){ const fl=await h.getFile();
    uploads.push({name:n,size:fl.size,bytes:new Uint8Array(await fl.arrayBuffer())}); } } }catch(e){ uploads=[]; }
  syncLoadFiles(); }

/* persist the linked directory handle across sessions (IndexedDB) */
function idbHandle(method,key,val){ return new Promise((res,rej)=>{
  const o=indexedDB.open("k16",1);
  o.onupgradeneeded=()=>o.result.createObjectStore("h");
  o.onerror=()=>rej(o.error);
  o.onsuccess=()=>{ const db=o.result; const tx=db.transaction("h","readwrite"); const st=tx.objectStore("h");
    const rq = method==="set" ? st.put(val,key) : method==="del" ? st.delete(key) : st.get(key);
    rq.onsuccess=()=>res(rq.result); rq.onerror=()=>rej(rq.error); }; }); }

function updateFolderLabel(){
  const nm=$("fx-folder-name"), btn=$("fx-link"), fx=$("fx-drop"); if(!nm) return;
  fx.classList.toggle("linked", !!linkedDir);
  if(linkedDir){ nm.textContent=linkedDir.name; nm.dataset.tip="linked local folder";
    btn.textContent="Unlink"; btn.dataset.state="linked"; btn.hidden=false; }
  else if(pendingDir){ nm.textContent=pendingDir.name; nm.dataset.tip="permission needed";
    btn.textContent="Reconnect"; btn.dataset.state="pending"; btn.hidden=false; }
  else { nm.textContent="uploads"; nm.dataset.tip="built-in browser storage";
    if(window.showDirectoryPicker){ btn.textContent="Link folder\u2026"; btn.dataset.state="unlinked"; btn.hidden=false; }
    else btn.hidden=true; }
}
async function linkFolder(){
  if(!window.showDirectoryPicker){ logPush("folder linking needs a Chromium browser"); return; }
  try{ const h=await window.showDirectoryPicker({mode:"readwrite", id:"k16-uploads"});
    linkedDir=h; pendingDir=null; await idbHandle("set","uploads",h);
    logPush("linked folder: "+h.name); await loadUploads(); applyPersistUI(); renderFiles(); updateFolderLabel();
  }catch(e){ if(e && e.name==="AbortError") return;
    logPush("couldn't link folder ("+((e&&e.name)||"error")+") \u2014 serve over http/https"); }
}
async function unlinkFolder(){ linkedDir=null; pendingDir=null; try{ await idbHandle("del","uploads"); }catch(e){}
  logPush("unlinked \u2014 back to built-in storage"); await loadUploads(); applyPersistUI(); renderFiles(); updateFolderLabel(); }
async function reconnectFolder(){ if(!pendingDir) return;
  try{ const p=await pendingDir.requestPermission({mode:"readwrite"});
    if(p==="granted"){ linkedDir=pendingDir; pendingDir=null;
      logPush("reconnected folder: "+linkedDir.name); await loadUploads(); applyPersistUI(); renderFiles(); updateFolderLabel(); }
    else logPush("permission denied"); }catch(e){} }
async function restoreLink(){ try{ const h=await idbHandle("get","uploads"); if(!h) return;
    const p=await h.queryPermission({mode:"readwrite"});
    if(p==="granted") linkedDir=h; else pendingDir=h;   // pending needs a click to re-grant
  }catch(e){} }

function openFiles(){ $("settings-pop").hidden=true; $("b-gear").classList.remove("active"); closeDrives();
  $("files-pop").hidden=false; $("b-files").classList.add("active"); renderFiles(); updateFolderLabel(); }
function closeFiles(){ $("files-pop").hidden=true; $("b-files").classList.remove("active"); }
$("b-files").onclick=(e)=>{ e.stopPropagation(); $("files-pop").hidden?openFiles():closeFiles(); };
$("fx-add").onclick=()=>$("fx-file").click();
$("fx-file").onchange=(e)=>{ if(e.target.files.length) addUploads(e.target.files); e.target.value=""; };
$("fx-remove").onclick=()=>{ if(selFile) removeFile(selFile); };
$("fx-link").onclick=(e)=>{ e.stopPropagation(); const st=$("fx-link").dataset.state;
  if(st==="linked") unlinkFolder(); else if(st==="pending") reconnectFolder(); else linkFolder(); };
$("files-pop").addEventListener("click",e=>e.stopPropagation());
(function(){ const dz=$("fx-drop");
  ["dragenter","dragover"].forEach(ev=>dz.addEventListener(ev,e=>{ e.preventDefault(); dz.classList.add("drag"); }));
  ["dragleave","drop"].forEach(ev=>dz.addEventListener(ev,e=>{ e.preventDefault();
    if(ev==="drop"||!dz.contains(e.relatedTarget)) dz.classList.remove("drag"); }));
  dz.addEventListener("drop",e=>{ if(e.dataTransfer && e.dataTransfer.files.length) addUploads(e.dataTransfer.files); });
})();
document.addEventListener("click",(e)=>{ const p=$("files-pop");
  if(!p.hidden && !p.contains(e.target) && !e.target.closest("#b-files")) closeFiles(); });

/* ---- Drives: ROM/RAM intrinsic; C-F user drives in the OPFS bay ---- */
/* The host (Core) owns the catalogue + bay bindings (the state k/OS sees).
   bay[]/mounted{} below are a VIEW of host truth, refreshed via
   refreshDisksFromHost(); every mount/unmount/create/delete/rename routes
   through Core.host* so the UI buttons and kosh commands run identical logic.
   Images persist in OPFS disks/ as NAME.KOS. */
let bay=[];                 // view of Core catalogue: {name(basename),size,fmt,bytes}
let mounted={};             // letter -> image basename (view of Core bays)
let _prevDiskNames=[];      // catalogue names at last sync (for OPFS rename/delete reconcile)
const ROMRAM=[ {id:"ROM",label:"ROM:",dot:"ro", meta:"ROM \u00b7 read-only"},
               {id:"RAM",label:"RAM:",dot:"vol",meta:"RAM \u00b7 volatile"} ];
let activeDrive="C";
let diskLinkedDir=null, diskPendingDir=null, fmtMap={};
function fmtSize(n){ return n>=1048576 ? (n/1048576).toFixed(n%1048576?1:0)+" MB" : (n/1024).toFixed(0)+" KB"; }
function blinkDrive(id,kind){ const chip=document.querySelector('#dstrip .dchip[data-id="'+id+'"]');
  if(!chip) return; chip.classList.remove("act-r","act-w"); chip.classList.add(kind==="write"?"act-w":"act-r");
  clearTimeout(chip._t); chip._t=setTimeout(()=>chip.classList.remove("act-r","act-w"),180); }

const BAYS=["C","D","E","F"];
function bayIdx(L){ return BAYS.indexOf(L); }
function baseName(n){ return (n||"").toString().toUpperCase().replace(/\.KOS$/i,""); }

// Mirror the OPFS-loaded images into the host catalogue (shared byte arrays).
function syncCatalogueToHost(){
  Core.diskCatalogueSet(bay.map(b=>({ name:baseName(b.name), data:b.bytes||new Uint8Array(b.size), ro:false })));
  _prevDiskNames=Core.catalogueImages().map(e=>e.name);
}
// Rebuild bay[]/mounted{} as a view of host truth (after any change).
function refreshDisksFromHost(){
  const imgs=Core.catalogueImages(), st=Core.getDiskState();
  bay=imgs.map(e=>({ name:e.name, size:e.data.length, fmt:!!fmtMap[e.name], bytes:e.data }))
          .sort((a,b)=>a.name.localeCompare(b.name));
  mounted={}; st.bays.forEach((nm,i)=>{ if(nm) mounted[BAYS[i]]=nm; });
  if(!mountedLetters().includes(activeDrive)) activeDrive=mountedLetters()[0]||activeDrive;
}
// Bind persisted mounts (the [Disks] equivalent) into host bays BEFORE boot.
function bindPersistedMounts(persisted){
  for(const L of BAYS){ const nm=persisted[L]; if(!nm) continue;
    const r=Core.hostMount(baseName(nm), bayIdx(L));
    if(r!==0) logPush("auto-mount "+baseName(nm)+" on "+L+": failed ("+r+")");
  }
  refreshDisksFromHost();
}

// Persistence: host catalogue/bay mutations -> re-render + persist mount map.
// (Specific create/import/delete/rename handlers persist the affected image;
//  sector writes persist via onBayDirty below.)
if(typeof Core!=="undefined" && Core){
  Core.onDiskChange=()=>{ refreshDisksFromHost();
    const now=Core.catalogueImages().map(e=>e.name);
    // names that vanished (renamed-away or deleted) -> drop their OPFS file
    _prevDiskNames.filter(n=>!now.includes(n)).forEach(n=>deleteDiskImage(n+".KOS"));
    // names that appeared (created/imported or renamed-to) -> persist
    Core.catalogueImages().forEach(e=>{ if(!_prevDiskNames.includes(e.name)) saveDiskImage(e.name+".KOS", e.data); });
    _prevDiskNames=now;
    renderStrip(); renderDriveList(); saveIni(); };
  // Debounced OPFS flush of a written/formatted bay image.
  const _flushT={};
  Core.onBayDirty=(b,bayObj)=>{ const L=BAYS[b]; blinkDrive(L,"write");
    clearTimeout(_flushT[b]); _flushT[b]=setTimeout(()=>{ if(bayObj&&bayObj.data) saveDiskImage(bayObj.name+".KOS", bayObj.data); }, 1000); };
}

function imgByName(n){ const b=baseName(n); return bay.find(x=>x.name===b); }
function mountLetterOf(name){ const b=baseName(name); return Object.keys(mounted).find(L=>mounted[L]===b)||null; }
function freeLetter(){ for(const L of BAYS) if(!mounted[L]) return L; return null; }
function mountedLetters(){ return Object.keys(mounted).sort(); }


function renderStrip(){
  const chips=[...ROMRAM.map(d=>({id:d.id,label:d.label,dot:d.dot})),
    ...mountedLetters().map(L=>({id:L,label:L+":",dot:"rw"}))];
  $("dstrip").innerHTML=chips.map(d=>'<button class="dchip'+(d.id===activeDrive?" active":"")+'" data-id="'+d.id+'">'+
    '<span class="ddot '+d.dot+'"></span>'+d.label+'</button>').join("");
  document.querySelectorAll("#dstrip .dchip").forEach(c=>c.onclick=(e)=>{ e.stopPropagation(); openDrives(); });
}
function drow(dotCls,label,meta,btns){ return '<div class="drow"><span class="dlabel"><span class="ddot '+dotCls+'"></span>'+label+'</span><span class="dmeta">'+meta+'</span>'+btns+'</div>'; }
function dgrp(t){ return '<div class="dgroup">'+t+'</div>'; }
let selImg=null;
function selrow(dotCls,label,meta,img){
  return '<div class="drow selrow'+(selImg===img?" sel":"")+'" data-img="'+img+'">'+
    '<span class="dlabel"><span class="ddot '+dotCls+'"></span>'+label+'</span>'+
    '<span class="dmeta">'+meta+'</span></div>';
}
function renderDriveList(){
  let h=dgrp("Built-in");
  ROMRAM.forEach(d=> h+=drow(d.dot,d.label,d.meta,'<span class="dlock">built-in</span>'));
  h+=dgrp("Mounted"); const ml=mountedLetters();
  if(!ml.length) h+='<div class="dnote">nothing mounted</div>';
  ml.forEach(L=>{ const im=imgByName(mounted[L]);
    h+=selrow("rw",L+":",(im?im.name+" \u00b7 "+fmtSize(im.size):"?"),mounted[L]); });
  const unm=bay.filter(b=>!mountLetterOf(b.name));
  h+=dgrp("Unmounted");
  if(!unm.length) h+='<div class="dnote">(empty)</div>';
  unm.forEach(b=> h+=selrow("dim",b.name,fmtSize(b.size)+" \u00b7 "+(b.fmt?"FAT16":"unformatted"),b.name));
  const sel = selImg && (mountLetterOf(selImg)||imgByName(selImg)) ? selImg : null;
  const mountedSel = sel ? mountLetterOf(sel) : null;
  const primDis = !sel || (!mountedSel && !freeLetter());
  const dis=(ok)=> ok?"":" disabled";
  h+='<div class="dbar">'+
     '<button id="da-prim" class="prim"'+dis(!primDis)+'>'+(mountedSel?"Eject":"Mount")+'</button>'+
     '<button id="da-rename"'+dis(!!sel)+'>Rename</button>'+
     '<button id="da-export"'+dis(!!sel)+'>Export</button>'+
     '<button id="da-delete"'+dis(!!sel && !mountedSel)+'>Delete</button>'+
     '</div>';
  $("drive-list").innerHTML=h;
  document.querySelectorAll("#drive-list .selrow").forEach(r=>{
    r.onclick=()=>{ selImg=r.dataset.img; renderDriveList(); };
    r.ondblclick=()=>{ selImg=r.dataset.img; const L=mountLetterOf(selImg); L?ejectLetter(L):mountImage(selImg); };
  });
  const P=$("da-prim"); if(P) P.onclick=()=>{ if(!sel) return; const L=mountLetterOf(sel); L?ejectLetter(L):mountImage(sel); };
  const R=$("da-rename"); if(R) R.onclick=()=>{ if(sel) renameImage(sel); };
  const X=$("da-export"); if(X) X.onclick=()=>{ if(sel) exportImage(sel); };
  const D=$("da-delete"); if(D) D.onclick=()=>{ if(sel) deleteImage(sel); };
}
function addImported(file){
  const base=baseName(file.name);
  if(Core.catalogueImages().find(e=>e.name===base)){ logPush("bay already has "+base); return; }
  if(!/^[A-Z0-9_]{1,15}$/.test(base)){ logPush("invalid image name: "+file.name); return; }
  const r=new FileReader();
  r.onload=()=>{ const bytes=new Uint8Array(r.result);
    Core.diskCatalogueSet([...Core.catalogueImages(), {name:base, data:bytes, ro:false}]);
    fmtMap[base]=true; saveDiskImage(base+".KOS",bytes);
    logPush("imported "+base+".KOS ("+fmtSize(bytes.length)+")");
    const L=freeLetter(); if(L) Core.hostMount(base, bayIdx(L)); else logPush("no free letter \u2014 image left in bay");
    selImg=base; refreshDisksFromHost(); renderStrip(); renderDriveList(); saveIni(); };
  r.readAsArrayBuffer(file);
}
function cleanName(input){ let b=baseName((input||"").trim()).replace(/[^A-Z0-9_]/g,"").slice(0,15); return b||null; }
function freeDiskName(){ let n=1,nm; do{ nm="DISK"+n; n++; }while(imgByName(nm)); return nm; }
function newBlank(){ askName("New disk image","Create",freeDiskName(),true,(name,mb)=>{
  const base=cleanName(name);
  if(!base){ logPush("invalid image name"); return; }
  const sectors=Math.max(64, Math.floor((mb||8)*1024*1024/512));
  const r=Core.hostCreate(base, sectors);
  if(r!==0){ logPush("create "+base+" failed ("+r+")"); return; }
  fmtMap[base]=false;
  const e=Core.catalogueImages().find(x=>x.name===base); if(e) saveDiskImage(base+".KOS", e.data);
  logPush("new blank "+base+".KOS ("+fmtSize(sectors*512)+") \u2014 format on mount");
  const L=freeLetter(); if(L) Core.hostMount(base, bayIdx(L));
  selImg=base; refreshDisksFromHost(); renderStrip(); renderDriveList(); saveIni();
}); }
function renameImage(name){ const base=baseName(name);
  askName("Rename "+base,"Rename",base,false,(nn)=>{ const nb=cleanName(nn);
  if(!nb){ logPush("invalid name"); return; }
  if(nb===base) return;
  if(Core.catalogueImages().find(e=>e.name===nb)){ logPush(nb+" already exists"); return; }
  const L=mountLetterOf(base);
  if(L){ const r=Core.hostRename(bayIdx(L), nb); if(r!==0){ logPush("rename failed ("+r+")"); return; } }
  else { Core.diskCatalogueSet(Core.catalogueImages().map(e=> e.name===base?{name:nb,data:e.data,ro:e.ro}:e)); }
  const e=Core.catalogueImages().find(x=>x.name===nb); if(e) saveDiskImage(nb+".KOS", e.data); deleteDiskImage(base+".KOS");
  fmtMap[nb]=fmtMap[base]; delete fmtMap[base]; if(selImg===base) selImg=nb;
  logPush("renamed "+base+" \u2192 "+nb);
  refreshDisksFromHost(); renderStrip(); renderDriveList(); saveIni();
}); }
function mountImage(name){ const base=baseName(name); const L=freeLetter();
  if(!L){ logPush("no free letter (C\u2013F all mounted)"); return; }
  const r=Core.hostMount(base, bayIdx(L));
  if(r!==0){ logPush("mount "+base+" failed ("+r+")"); return; }
  if(!activeDrive) activeDrive=L;
  logPush("mounted "+base+" as "+L+":"); refreshDisksFromHost(); renderStrip(); renderDriveList(); saveIni(); }
function ejectLetter(L){ const name=mounted[L];
  const r=Core.hostUnmount(bayIdx(L)); if(r!==0){ logPush("eject "+L+": failed ("+r+")"); return; }
  if(activeDrive===L) activeDrive=mountedLetters().filter(x=>x!==L)[0]||null;
  logPush("ejected "+L+": ("+name+" stays in bay)"); refreshDisksFromHost(); renderStrip(); renderDriveList(); saveIni(); }
function deleteImage(name){ const base=baseName(name);
  if(mountLetterOf(base)){ logPush("eject "+base+" before deleting"); return; }
  if(!confirm("Delete "+base+".KOS from the bay? This destroys the image.")) return;
  const r=Core.hostDelete(base); if(r!==0){ logPush("delete failed ("+r+")"); return; }
  if(selImg===base) selImg=null; delete fmtMap[base]; deleteDiskImage(base+".KOS");
  logPush("deleted "+base+" from bay"); refreshDisksFromHost(); renderDriveList(); saveIni(); }
function exportImage(name){ const b=imgByName(name); if(!b) return;
  const bytes=b.bytes||new Uint8Array(b.size);
  const a=document.createElement("a"); a.href=URL.createObjectURL(new Blob([bytes],{type:"application/octet-stream"}));
  a.download=baseName(name)+".KOS"; a.click(); URL.revokeObjectURL(a.href); logPush("exported "+baseName(name)+".KOS"); }

/* ---- disk images: real bytes in OPFS disks/ or a linked local folder ---- */
async function disksDir(create){ if(diskLinkedDir) return diskLinkedDir;
  const root=await navigator.storage.getDirectory();
  return await root.getDirectoryHandle("disks",{create:!!create}); }
async function saveDiskImage(name,bytes){ try{ const d=await disksDir(true);
  const fh=await d.getFileHandle(name,{create:true}); const w=await fh.createWritable();
  await w.write(bytes); await w.close(); }catch(e){} }
async function deleteDiskImage(name){ try{ const d=await disksDir(false); await d.removeEntry(name); }catch(e){} }
async function loadDiskImages(){
  try{ const d=await disksDir(false); const found=[];
    for await (const [n,h] of d.entries()){ if(h.kind==="file" && /\.KOS$/i.test(n)){ const fl=await h.getFile();
      const base=baseName(n);
      found.push({name:base,size:fl.size,fmt:!!fmtMap[base],bytes:new Uint8Array(await fl.arrayBuffer())}); } }
    bay=found.sort((a,b)=>a.name.localeCompare(b.name));
  }catch(e){ bay=[]; }
  // No default disk: a clean boot is ROM:+RAM: only. User images persist in OPFS.
  Object.keys(mounted).forEach(L=>{ mounted[L]=baseName(mounted[L]); if(!imgByName(mounted[L])) delete mounted[L]; });
  syncCatalogueToHost();          // mirror OPFS catalogue into the host (bays bound pre-boot in startup)
}
function updateDriveFolderLabel(){ const nm=$("dfx-name"), btn=$("dfx-link"), hd=$("dfx-head"); if(!nm) return;
  hd.classList.toggle("linked",!!diskLinkedDir);
  if(diskLinkedDir){ nm.textContent=diskLinkedDir.name; nm.dataset.tip="linked local folder"; btn.textContent="Unlink"; btn.dataset.state="linked"; btn.hidden=false; }
  else if(diskPendingDir){ nm.textContent=diskPendingDir.name; nm.dataset.tip="permission needed"; btn.textContent="Reconnect"; btn.dataset.state="pending"; btn.hidden=false; }
  else { nm.textContent="disks"; nm.dataset.tip="built-in browser storage";
    if(window.showDirectoryPicker){ btn.textContent="Link folder\u2026"; btn.dataset.state="unlinked"; btn.hidden=false; } else btn.hidden=true; } }
async function linkDisksFolder(){ if(!window.showDirectoryPicker){ logPush("folder linking needs a Chromium browser"); return; }
  try{ const h=await window.showDirectoryPicker({mode:"readwrite", id:"k16-disks"});
    diskLinkedDir=h; diskPendingDir=null; await idbHandle("set","disks",h);
    logPush("linked disks folder: "+h.name); await loadDiskImages(); applyPersistUI(); renderStrip(); renderDriveList(); updateDriveFolderLabel();
  }catch(e){ if(e && e.name==="AbortError") return; logPush("couldn't link folder \u2014 serve over http/https"); } }
async function unlinkDisksFolder(){
  const ml=mountedLetters();
  if(ml.length && !confirm("Unlink the disks folder?\n"+ml.map(L=>L+":").join(", ")+" will be unmounted. Your image files stay on disk.")) return;
  diskLinkedDir=null; diskPendingDir=null; try{ await idbHandle("del","disks"); }catch(e){}
  logPush("unlinked disks \u2014 back to built-in storage"); await loadDiskImages(); applyPersistUI(); renderStrip(); renderDriveList(); updateDriveFolderLabel(); }
async function reconnectDisks(){ if(!diskPendingDir) return; try{ const p=await diskPendingDir.requestPermission({mode:"readwrite"});
  if(p==="granted"){ diskLinkedDir=diskPendingDir; diskPendingDir=null; logPush("reconnected disks: "+diskLinkedDir.name); await loadDiskImages(); applyPersistUI(); renderStrip(); renderDriveList(); updateDriveFolderLabel(); } else logPush("permission denied"); }catch(e){} }
async function restoreDiskLink(){ try{ const h=await idbHandle("get","disks"); if(!h) return;
  const p=await h.queryPermission({mode:"readwrite"}); if(p==="granted") diskLinkedDir=h; else diskPendingDir=h; }catch(e){} }

function openDrives(){ $("settings-pop").hidden=true; $("b-gear").classList.remove("active"); closeFiles(); if($("dname")) $("dname").hidden=true;
  $("drives-pop").hidden=false; $("b-drives").classList.add("active"); renderDriveList(); updateDriveFolderLabel(); }
function closeDrives(){ $("drives-pop").hidden=true; $("b-drives").classList.remove("active"); }
$("b-drives").onclick=(e)=>{ e.stopPropagation(); $("drives-pop").hidden?openDrives():closeDrives(); };
$("dr-add").onclick=()=>$("dr-file").click();
$("dr-file").onchange=(e)=>{ const f=e.target.files[0]; if(f) addImported(f); e.target.value=""; };
$("dr-new").onclick=()=>newBlank();
$("drives-pop").addEventListener("click",e=>e.stopPropagation());
$("dfx-link").onclick=(e)=>{ e.stopPropagation(); const st=$("dfx-link").dataset.state;
  if(st==="linked") unlinkDisksFolder(); else if(st==="pending") reconnectDisks(); else linkDisksFolder(); };
function askName(title,okLabel,initial,withSize,cb){
  $("dname-title").textContent=title; $("dname-ok").textContent=okLabel;
  $("dname-srow").hidden=!withSize;
  const inp=$("dname-input"); inp.value=(initial||"").toUpperCase().replace(/[^A-Z0-9_]/g,"").slice(0,8);
  $("dname")._cb=cb; $("dname").hidden=false; setTimeout(()=>{ inp.focus(); inp.select(); },0);
}
function closeName(){ $("dname").hidden=true; $("dname")._cb=null; }
$("dname-input").addEventListener("input",e=>{ e.target.value=e.target.value.toUpperCase().replace(/[^A-Z0-9_]/g,"").slice(0,8); });
$("dname-input").addEventListener("keydown",e=>{ if(e.key==="Enter"){ e.preventDefault(); $("dname-ok").click(); } else if(e.key==="Escape"){ e.preventDefault(); closeName(); } });
$("dname-ok").onclick=()=>{ const v=$("dname-input").value.trim(); const mb=parseInt($("dname-size").value)||8; const cb=$("dname")._cb; closeName(); if(cb) cb(v||null, mb); };
$("dname-cancel").onclick=()=>closeName();
document.addEventListener("click",(e)=>{ const p=$("drives-pop");
  if(!p.hidden && !p.contains(e.target) && !e.target.closest("#b-drives") && !e.target.closest("#dstrip")) closeDrives(); });

// Popover close buttons (X) — route each to its existing close path.
document.querySelectorAll(".pop-x").forEach(b=>b.addEventListener("click",e=>{
  e.stopPropagation();
  switch(b.dataset.close){
    case "settings-pop": $("settings-pop").hidden=true; $("b-gear").classList.remove("active"); break;
    case "files-pop":  closeFiles();  break;
    case "drives-pop": closeDrives(); break;
  }
}));

/* ---- k16.ini in the OPFS bay (best-effort; no-ops on file://) ---- */
function serializeIni(){
  let t="[display]\npalette="+$("set-term").value+"\nspeed="+(fast?"fast":"mhz")+
        "\nmhz="+mhz+"\nupdate_disasm="+(disUpdate?1:0)+"\ndisk_log="+(diskLog?1:0)+"\ngfx_scale="+gfxScaleMode+"\n\n[bay]\n";
  bay.forEach(b=>{ t+=b.name+"="+(b.fmt?1:0)+"\n"; });
  t+="\n[mounts]\n";
  Object.keys(mounted).forEach(L=>{ t+=L+"="+mounted[L]+"\n"; });
  return t;
}
async function saveIni(){ try{ const root=await navigator.storage.getDirectory();
  const fh=await root.getFileHandle("k16.ini",{create:true});
  const w=await fh.createWritable(); await w.write(serializeIni()); await w.close(); }catch(e){} }
async function loadIni(){ try{ const root=await navigator.storage.getDirectory();
  const fh=await root.getFileHandle("k16.ini"); return await (await fh.getFile()).text(); }catch(e){ return null; } }
function applyIni(txt){ if(!txt) return; let sec="", nm={};
  txt.split(/\r?\n/).forEach(line=>{ line=line.trim(); if(!line||line[0]===";") return;
    const m=line.match(/^\[(.+)\]$/); if(m){ sec=m[1]; return; }
    const i=line.indexOf("="); if(i<0) return; const k=line.slice(0,i), v=line.slice(i+1);
    if(sec==="display"){
      if(k==="palette"){ $("set-term").value=v; setTermTheme(v); }
      else if(k==="speed"){ setSpeedMode(v!=="mhz"); }
      else if(k==="mhz"){ mhz=parseInt(v)||10; $("spd-val").value=mhz; }
      else if(k==="update_disasm"){ disUpdate=v==="1"; $("set-disupd").checked=disUpdate; Core.setTrace(disUpdate); }
      else if(k==="disk_log"){ diskLog=v==="1"; $("set-disklog").checked=diskLog; }
      else if(k==="gfx_scale"){ if(v==="fractional"||v==="device"||v==="integer"){ gfxScaleMode=v; $("set-gfxscale").value=v; } }
      else if(k==="gfx_fractional"){ gfxScaleMode=(v==="1")?"fractional":"integer"; $("set-gfxscale").value=gfxScaleMode; }   // legacy key
    } else if(sec==="bay"){ const p=v.split(","); fmtMap[k]= p.length>1 ? p[1]==="1" : p[0]==="1"; }
    else if(sec==="mounts"){ const L=k.toUpperCase(); if(["C","D","E","F"].includes(L)) nm[L]=v; }
  });
  if(Object.keys(nm).length) mounted=nm;
}
async function bootPersist(){ persistOK=await checkPersist(); await restoreLink(); await restoreDiskLink(); applyPersistUI(); applyIni(await loadIni()); await loadDiskImages(); await loadUploads(); renderStrip(); renderDriveList(); renderFiles(); updateFolderLabel(); updateDriveFolderLabel(); renderStatus(); }

window.addEventListener("keydown",e=>{
  if(e.code==="Space"&&!/input|textarea/i.test(e.target.tagName)){
    e.preventDefault(); running?$("b-pause").onclick():$("b-run").onclick(); } });

async function startup(){
  if(vt) vt.reset(); setTermTheme("green"); layoutScreen(); refreshAll(); renderLog(); alignLegend(); renderStrip();
  await bootPersist();              // restore INI mounts + load OPFS catalogue -> host catalogue
  Core.setTrace(disUpdate);         // gate before-PC history recording to the checkbox
  bindPersistedMounts(mounted);     // bind persisted [mounts] into host bays BEFORE k/OS boots
  renderStrip(); renderDriveList();
  await Core.boot();                // k/OS detects pre-mounted media at boot
  if(vt) vt.reset(); memBase=Core.BASE; pumpTTY(); refreshAll(); pumpLog(); setRunning(true); $("term").focus();
}
startup();
window.addEventListener("load", alignLegend);
requestAnimationFrame(frame);
