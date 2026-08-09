// k16-isa-grid.js - interactive opcode decode grid (renderer).
//
// Reads window.K16_OPCODES (factual) + window.K16_OPCODE_DETAIL (curated) and
// builds the whole UI inside a host element. All DOM and CSS are scoped under a
// single .isa root, so nothing collides with WebEMU's bare table/.tab/.card etc.
//
// Hosts: WebEMU panel <div id="isawrap" data-isa> and the standalone k16-isa.html
// shell <div data-isa>. Both just provide an empty container with [data-isa];
// this script auto-mounts into every such element on load. No host JS needed
// beyond the tab show/hide.
//
// Load order: k16-isa-data.js, k16-isa-detail.js, then this file.

(function (root) {
  'use strict';

  // ---- family palette : keys map to --f-* CSS vars defined in k16-isa.css ----
  const FAM = {
    sys:   {c:'--f-sys',   t:'control / system', s:'ctrl'},
    incdec:{c:'--f-incdec',t:'inc / dec XY',     s:'inc/dec'},
    lookup:{c:'--f-lookup',t:'lookup / shift',   s:'lookup'},
    stream:{c:'--f-stream',t:'stream',           s:'stream'},
    addr:  {c:'--f-addr',  t:'address (LEA)',    s:'addr'},
    cond:  {c:'--f-cond',  t:'cond set',         s:'cond'},
    move:  {c:'--f-move',  t:'move',             s:'move'},
    stack: {c:'--f-stack', t:'stack',            s:'stack'},
    alu:   {c:'--f-alu',   t:'ALU',              s:'ALU'},
    cmp:   {c:'--f-cmp',   t:'compare',          s:'cmp'},
    branch:{c:'--f-branch',t:'branch',           s:'branch'},
    flow:  {c:'--f-flow',  t:'jump / call',      s:'jump'},
    load:  {c:'--f-load',  t:'load',             s:'load'},
    store: {c:'--f-store', t:'store',            s:'store'},
    trap:  {c:'--f-trap',  t:'trap / return',    s:'trap'},
  };
  const MODES = ['00','01','10','11'];

  // Opcodes where the 6502 borrow-sense matters: SUB, SBC, CMP, Bcc.
  const CARRY_OPS = new Set([0x0A,0x0B,0x10,0x11]);
  const CARRY_HTML =
    '<b>6502 carry</b> - after SUB / SBC / CMP: C=1 = no borrow (A&nbsp;&ge;&nbsp;B), '
    +'C=0 = borrow (A&nbsp;&lt;&nbsp;B). BCS/BHS = &ge;, BCC/BLO = &lt;. Shifts leave C untouched.';

  function hx(n){ return '$'+n.toString(16).toUpperCase().padStart(2,'0'); }

  // ---- adapt the loaded data files to the internal positional shape ----
  function buildG(){
    const out={}, src=root.K16_OPCODES||{};
    Object.keys(src).forEach(k=>{
      const op=parseInt(k,16), e=src[k], modes={};
      MODES.forEach(m=>{
        const md=e.modes[m];
        if(!md||md.reserved){ modes[m]=['~','','','']; return; }
        const arr=[md.mnem, md.syntax||'', md.cycles||'', md.flags||'----', md.note||''];
        if(md.family) arr[5]=md.family;
        modes[m]=arr;
      });
      out[op]=[e.family,e.name,modes];
      if(e.variants) out[op][3]=e.variants;
    });
    return out;
  }
  function buildRICH(){
    const out={}, src=root.K16_OPCODE_DETAIL||{};
    Object.keys(src).forEach(k=>{
      if(k.indexOf('.')>=0) out[k]=src[k];      // mode-specific  "OP.mm"  (modes differ, e.g. $00)
      else out[parseInt(k,16)]=src[k];          // opcode-level   (all modes are one instruction, e.g. CMP)
    });
    return out;
  }

  function flagSpan(f){
    const names=['C','Z','N','V'];
    if(!f) f='----';
    return names.map((n,i)=>{
      const ch=f[i]||'-', on=ch!=='-';
      return '<span class="fchip'+(on?' on':'')+'">'+n+(on?ch:'')+'</span>';
    }).join('');
  }

  // ---- skeleton built inside the host (everything scoped under .isa) ----
  const SKELETON =
    '<div class="isa-bar">'
    +'<span class="isa-logo">K<b>16</b> <span class="lbl">opcodes</span></span>'
    +'<div class="isa-find"><div class="isa-find-box">'
    +'<input class="isa-q" type="text" placeholder="filter opcodes  (e.g. LOAD, BCS, STREAM)" autocomplete="off" spellcheck="false" aria-label="Filter opcodes">'
    +'<span class="isa-hits"></span>'
    +'<button class="isa-q-x" hidden aria-label="Clear filter">&#x2715;</button>'
    +'</div></div>'
    +'</div>'
    +'<div class="isa-body">'
    +'<div class="isa-controls">'
    +'<div class="isa-legend" aria-label="Instruction families (tap to highlight)"></div>'
    +'</div>'
    +'<div class="isa-gridwrap"><table><thead><tr>'
    +'<th class="opcol">Opcode</th><th>mode 00</th><th>mode 01</th><th>mode 10</th><th>mode 11</th>'
    +'</tr></thead><tbody class="isa-grid"></tbody></table></div>'
    +'<div class="isa-foot"><span class="flg">FLAGS C Z N V -</span> '
    +'<span class="on">*</span> set &middot; - unaffected &middot; 0 cleared &middot; 1 set &middot; w written. '
    +'Cycles at 10&nbsp;MHz; <b>a/b</b> = no-cross / page-cross. '
    +'$1E/$1F per K16 Reference Manual &sect;15.2.</div>'
    +'</div>'
    +'<div class="isa-scrim"></div>'
    +'<aside class="isa-drawer" aria-hidden="true" role="dialog" aria-label="Instruction detail">'
    +'<button class="isa-x">esc</button><div class="isa-dbody"></div></aside>';

  function mount(host){
    if(host.dataset.isaMounted) return;
    host.dataset.isaMounted='1';
    host.classList.add('isa');
    host.innerHTML = SKELETON;

    const G = buildG(), RICH = buildRICH();
    const $ = sel => host.querySelector(sel);
    const legendEl = $('.isa-legend');
    const gridEl   = $('.isa-grid');
    const q        = $('.isa-q');
    const hitsEl   = $('.isa-hits');
    const clearBtn = $('.isa-q-x');
    const drawer   = $('.isa-drawer');
    const scrim    = $('.isa-scrim');
    const dbody    = $('.isa-dbody');
    const closeBtn = $('.isa-x');
    const activeFams = new Set();

    // ---- legend ----
    Object.keys(FAM).forEach(k=>{
      const v=FAM[k];
      const b=document.createElement('button');
      b.className='isa-chip';b.setAttribute('aria-pressed','false');b.dataset.fam=k;
      b.innerHTML='<span class="sw" style="background:var('+v.c+')"></span>'+(v.s||v.t);
      b.onclick=()=>{
        if(activeFams.has(k)){activeFams.delete(k);b.setAttribute('aria-pressed','false');}
        else{activeFams.add(k);b.setAttribute('aria-pressed','true');}
        applyFilters();
      };
      legendEl.appendChild(b);
    });

    // ---- grid ----
    for(let op=0x00;op<=0x1F;op++){
      const e=G[op]; if(!e) continue;
      const fam=e[0], name=e[1], modes=e[2];
      const tr=document.createElement('tr');tr.dataset.fam=fam;
      const td0=document.createElement('td');td0.className='op';
      td0.style.setProperty('--fc','var('+FAM[fam].c+')');
      td0.innerHTML='<span class="hx">'+hx(op)+'</span> <span class="nm">'+name+'</span><span class="fam">'+FAM[fam].t+'</span>';
      tr.appendChild(td0);
      MODES.forEach(m=>{
        const cell=document.createElement('td');
        const d=modes[m];
        if(!d||d[0]==='~'){
          cell.className='cell empty';cell.innerHTML='<span class="mn">-</span>';
        }else{
          const cf=d[5]||fam;
          cell.className='cell';
          cell.style.setProperty('--fc','var('+FAM[cf].c+')');
          cell.tabIndex=0;cell.setAttribute('role','button');
          cell.innerHTML='<span class="ml" aria-hidden="true">mode '+m+'</span><div class="mn">'+d[0]+'</div><div class="cy">'+d[2]+' cyc</div>';
          cell.dataset.op=op;cell.dataset.mode=m;cell.dataset.fam=cf;
          cell.dataset.search=(name+' '+d[0]+' '+d[1]+' '+((e[3]||[]).join(' '))).toLowerCase();
          const open=()=>openDetail(op,m,cell);
          cell.addEventListener('click',open);
          cell.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();open();}});
        }
        tr.appendChild(cell);
      });
      gridEl.appendChild(tr);
    }

    // ---- detail drawer ----
    function openDetail(op,m,cell){
      gridEl.querySelectorAll('.cell.sel').forEach(c=>c.classList.remove('sel'));
      if(cell) cell.classList.add('sel');
      const e=G[op], fam=e[0], name=e[1], modes=e[2], variants=e[3];
      const d=modes[m];
      const cf=d[5]||fam;
      const fc='var('+FAM[cf].c+')';
      let html='<div class="d-fam" style="--fc:'+fc+'">'+FAM[cf].t+'</div>';
      const ohex=op.toString(16).toUpperCase().padStart(2,'0');
      const perMode=RICH[ohex+'.'+m];
      const rich=perMode||RICH[op];
      // title: LOOKUP is per-Dn; per-mode entries show the mode's own mnemonic; else the opcode name
      const title = (op===0x01) ? ('LOOKUP D'+MODES.indexOf(m)+', #page')
                  : (perMode ? d[0] : name);
      html+='<div class="d-op"><span class="hx">'+hx(op)+'</span> '+title+'</div>';
      html+='<div class="d-mode">opcode '+hx(op)+' &middot; mode '+m+' &middot; '+name+'</div>';
      html+='<div class="d-syn">'+d[1]+'</div>';
      html+='<div class="d-row">'
        +'<div class="d-box"><div class="lab">cycles</div><div class="val">'+d[2]+'</div></div>'
        +'<div class="d-box"><div class="lab">flags</div><div class="val fchips">'+flagSpan(d[3])+'</div></div></div>';
      if(d[4]) html+='<div class="d-note">'+d[4]+'</div>';
      if(CARRY_OPS.has(op)) html+='<div class="d-carry">'+CARRY_HTML+'</div>';
      if(variants&&variants.length&&!(rich&&(rich.pages||rich.condTable))){
        html+='<div class="d-variants"><div class="vh">all mnemonics under '+hx(op)+'</div><ul>';
        variants.forEach(v=>{html+='<li><span>'+v+'</span></li>';});
        html+='</ul></div>';
      }
      if(rich){
        if(rich.pages){
          html+='<div class="d-sec"><div class="vh">built-in table pages (Dn = page[Dn])</div><table class="d-tbl pages"><tbody>';
          rich.pages.forEach(p=>{html+='<tr><td class="mono">'+p[0]+'</td><td class="mono bits">'+p[1]+'</td><td>'+p[2]+'</td></tr>';});
          html+='</tbody></table></div>';
        }
        if(rich.oper)
          html+='<div class="d-sec"><div class="vh">operation</div><div class="d-oper">'+rich.oper+'</div></div>';
        if(rich.enc){
          html+='<div class="d-sec"><div class="vh">encoding (instruction word)</div><table class="d-tbl enc"><tbody>';
          rich.enc.forEach(e=>{
            html+='<tr><td class="mono">'+e[0]+'</td><td class="mono bits">'+e[1]+'</td></tr>';
            if(e[2]) html+='<tr class="enc-note"><td colspan="2">'+e[2]+'</td></tr>';
          });
          html+='</tbody></table></div>';
        }
        if(rich.forms){
          html+='<div class="d-sec"><div class="vh">forms</div><table class="d-tbl"><tbody>';
          rich.forms.forEach(f=>{html+='<tr><td class="mono">'+f[0]+'</td><td class="dim">'+f[1]+'</td><td class="num">'+f[2]+' cyc</td><td class="num">'+(f[3]||'1')+' w</td></tr>';});
          html+='</tbody></table></div>';
        }
        if(rich.debug)
          html+='<div class="d-sec"><div class="vh">debug</div><div class="d-oper">'+rich.debug+'</div></div>';
        if(rich.flagsDetail){
          html+='<div class="d-sec"><div class="vh">what the flags mean</div><table class="d-tbl"><tbody>';
          rich.flagsDetail.forEach(f=>{html+='<tr><td class="mono accent">'+f[0]+'</td><td>'+f[1]+'</td></tr>';});
          html+='</tbody></table></div>';
        }
        if(rich.branches){
          html+='<div class="d-sec"><div class="vh">branch with ('+(rich.branchHead||'after CMP A,B')+')</div>'
            +'<table class="d-tbl br"><thead><tr><th>want</th><th>unsigned</th><th>signed</th></tr></thead><tbody>';
          rich.branches.forEach(b=>{html+='<tr><td>'+b[0]+'</td><td class="mono">'+b[1]+'</td><td class="mono">'+b[2]+'</td></tr>';});
          html+='</tbody></table>';
          if(rich.branchNote) html+='<div class="d-fine">'+rich.branchNote+'</div>';
          html+='</div>';
        }
        if(rich.condTable){
          var ct=rich.condTable;
          html+='<div class="d-sec"><div class="vh">'+(ct.head||'conditions')+'</div>'
            +'<table class="d-tbl"><thead><tr>'+ct.cols.map(function(c){return '<th>'+c+'</th>';}).join('')+'</tr></thead><tbody>';
          ct.rows.forEach(function(r){
            html+='<tr>'+r.map(function(c,i){
              var cls=i===0?'mono accent':(i===r.length-1?'':'mono');
              return '<td'+(cls?' class="'+cls+'"':'')+'>'+c+'</td>';
            }).join('')+'</tr>';
          });
          html+='</tbody></table></div>';
        }
        if(rich.gotchas){
          html+='<div class="d-sec"><div class="vh">gotchas</div><ul class="d-bullets">';
          rich.gotchas.forEach(g=>{html+='<li>'+g+'</li>';});
          html+='</ul></div>';
        }
        if(rich.seeAlso){
          html+='<div class="d-sec"><div class="vh">see also</div><div class="d-see">';
          rich.seeAlso.forEach(s=>{html+='<span class="d-pill"><b>'+s[0]+'</b> '+s[1]+'</span>';});
          html+='</div></div>';
        }
      }
      dbody.style.setProperty('--fc', fc);
      dbody.innerHTML=html;
      drawer.classList.add('open');scrim.classList.add('open');
      drawer.setAttribute('aria-hidden','false');
      closeBtn.focus();
    }
    function closeDetail(){
      drawer.classList.remove('open');scrim.classList.remove('open');
      drawer.setAttribute('aria-hidden','true');
      gridEl.querySelectorAll('.cell.sel').forEach(c=>c.classList.remove('sel'));
    }
    closeBtn.onclick=closeDetail;
    scrim.onclick=closeDetail;
    host.addEventListener('keydown',ev=>{if(ev.key==='Escape')closeDetail();});

    // ---- search + family filter ----
    function applyFilters(){
      const term=q.value.trim().toLowerCase();
      const fams=activeFams;
      const anyFilter=term||fams.size;
      let hits=0;
      host.querySelectorAll('.isa-chip').forEach(c=>{
        c.classList.toggle('dim', fams.size>0 && !fams.has(c.dataset.fam));
      });
      gridEl.querySelectorAll('tr').forEach(tr=>{
        let rowHas=false;
        tr.querySelectorAll('.cell').forEach(cell=>{
          cell.classList.remove('hit','fade');
          if(cell.classList.contains('empty'))return;
          const famOk = !fams.size || fams.has(cell.dataset.fam);
          const termOk = !term || cell.dataset.search.includes(term);
          const match = famOk && termOk;
          if(anyFilter){
            if(match){cell.classList.add('hit');rowHas=true;hits++;}
            else cell.classList.add('fade');
          }else rowHas=true;
        });
        tr.classList.toggle('dim', anyFilter && !rowHas);
      });
      hitsEl.textContent = anyFilter ? String(hits) : '';
      clearBtn.hidden = !q.value;
    }
    q.addEventListener('input',applyFilters);
    clearBtn.onclick=()=>{ q.value=''; applyFilters(); q.focus(); };
  }

  function autoMount(){
    document.querySelectorAll('[data-isa]').forEach(mount);
  }

  root.K16ISA = { mount, autoMount, FAM };

  if(document.readyState==='loading')
    document.addEventListener('DOMContentLoaded', autoMount);
  else
    autoMount();

})(typeof window !== 'undefined' ? window : globalThis);
