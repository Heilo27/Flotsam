#!/usr/bin/env python3
"""Generates docs/design/src/*.html sheets. Render with render.sh. Icons are inline stand-ins for SF Symbols."""
import os
D = os.path.dirname(os.path.abspath(__file__))
P = {
 'search':'<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/>',
 'clock':'<circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.5 1.5"/>',
 'doc':'<path d="M4 1.8h5.2L12.5 5v9.2H4z"/><path d="M9 1.8V5h3.5"/>',
 'text':'<path d="M3 4h10M3 8h10M3 12h6"/>',
 'link':'<path d="M7 9a2.6 2.6 0 003.7 0l2-2a2.6 2.6 0 00-3.7-3.7l-.8.8"/><path d="M9 7a2.6 2.6 0 00-3.7 0l-2 2a2.6 2.6 0 003.7 3.7l.8-.8"/>',
 'image':'<rect x="2" y="3" width="12" height="10" rx="1.5"/><circle cx="6" cy="6.5" r="1"/><path d="M2.5 12l3.5-3.5 2.5 2 2-2 3 3"/>',
 'shot':'<path d="M2 5V3.5A1.5 1.5 0 013.5 2H5M11 2h1.5A1.5 1.5 0 0114 3.5V5M14 11v1.5a1.5 1.5 0 01-1.5 1.5H11M5 14H3.5A1.5 1.5 0 012 12.5V11"/><circle cx="8" cy="8" r="2"/>',
 'color':'<circle cx="8" cy="8" r="6"/><path d="M8 2a6 6 0 000 12z" class="fillme"/>',
 'folder':'<path d="M2 4.5A1.5 1.5 0 013.5 3h2.6l1.4 1.5h5A1.5 1.5 0 0114 6v5.5a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 012 11.5z"/>',
 'pin':'<path d="M9.5 2l4.5 4.5-2 .5-2.5 2.5.5 3-1 1-3-3-3.5 3.5M7 6l-.5 3"/>',
 'tag':'<path d="M2 8.2V3.5A1.5 1.5 0 013.5 2h4.7l5.8 5.8-5.2 5.2z"/><circle cx="5.3" cy="5.3" r=".9"/>',
 'note':'<path d="M3 2.5h10v8l-3 3H3z"/><path d="M10 13.5v-3h3M5.5 6h5M5.5 8.5h3"/>',
 'bolt':'<path d="M9 1.5L3.5 9H8l-1 5.5L12.5 7H8z"/>',
 'gear':'<circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4"/>',
 'kbd':'<rect x="1.5" y="4" width="13" height="8" rx="1.5"/><path d="M4 7h.1M6.5 7h.1M9 7h.1M11.5 7h.1M5 9.5h6"/>',
 'hand':'<path d="M8 1.8l5.6 2.3v3.6c0 3.2-2.2 5.6-5.6 6.7C4.6 13.3 2.4 10.9 2.4 7.7V4.1z"/><path d="M5.6 8l1.7 1.7L10.6 6.4"/>',
 'disk':'<ellipse cx="8" cy="4" rx="5.5" ry="2"/><path d="M2.5 4v8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2V4M2.5 8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2"/>',
 'info':'<circle cx="8" cy="8" r="6"/><path d="M8 7.2V11M8 5v.1"/>',
 'grid':'<rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/><rect x="2" y="9" width="5" height="5" rx="1"/><rect x="9" y="9" width="5" height="5" rx="1"/>',
 'list':'<path d="M5 4h9M5 8h9M5 12h9M2 4h.1M2 8h.1M2 12h.1"/>',
 'sort':'<path d="M4 3v10M2 11l2 2 2-2M10 4h4M10 8h3M10 12h2"/>',
 'x':'<path d="M4 4l8 8M12 4l-8 8"/>',
 'xc':'<circle cx="8" cy="8" r="6.2"/><path d="M5.8 5.8l4.4 4.4M10.2 5.8l-4.4 4.4"/>',
 'warn':'<path d="M8 2L14.5 13.5h-13z"/><path d="M8 6.5v3.2M8 11.6v.1"/>',
 'check':'<path d="M3 8.5l3.2 3.2L13 4.8"/>',
 'chev':'<path d="M6 3.5L10.5 8 6 12.5"/>',
 'chevd':'<path d="M3.5 6L8 10.5 12.5 6"/>',
 'updn':'<path d="M5 6.5L8 3.5l3 3M5 9.5l3 3 3-3"/>',
 'plus':'<path d="M8 3v10M3 8h10"/>',
 'minus':'<path d="M3 8h10"/>',
 'trash':'<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5"/>',
 'reveal':'<path d="M2 4.5A1.5 1.5 0 013.5 3h2.6l1.4 1.5h5A1.5 1.5 0 0114 6v5.5a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 012 11.5z"/><path d="M6 9.5h4M8.5 8l1.5 1.5L8.5 11"/>',
 'eye':'<path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>',
 'pause':'<path d="M6 3.5v9M10 3.5v9"/>',
 'edge':'<rect x="1.8" y="2.5" width="12.4" height="11" rx="1.8"/><path d="M10 2.5v11"/>',
 'swoosh':'<path d="M2 11c2-1.8 3.6-1.8 5.4 0s3.4 1.8 6.6-.4"/>',
 'lock':'<rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 015 0v2"/>',
 'login':'<path d="M2.5 3.5h6v9h-6M7 8h7M11.5 5.5L14 8l-2.5 2.5" />',
 'paste':'<rect x="3" y="3" width="10" height="11" rx="1.5"/><path d="M6 3V2h4v1M6 8h4M6 10.5h3"/>',
}
# Flotsam glyph: tilted plank over a wave (original)
GLYPH = {
 'active':'<g transform="rotate(-14 9 8)"><rect x="2.5" y="3.5" width="13" height="5" rx="1.6" fill="currentColor" stroke="none"/></g><path d="M2 12.2c1.7-1.6 3.1-1.6 4.7 0s3 1.6 4.6 0 3-1.6 4.7 0" />',
 'paused':'<g transform="rotate(-14 9 8)"><rect x="2.5" y="3.5" width="13" height="5" rx="1.6"/></g><path d="M2 12.2c1.7-1.6 3.1-1.6 4.7 0s3 1.6 4.6 0 3-1.6 4.7 0" /><path d="M7.4 1.2v3M10.6 1.2v3" stroke-width="1.6"/>',
 'curated':'<g transform="rotate(-14 9 8)"><rect x="2.5" y="3.5" width="13" height="5" rx="1.6" stroke-dasharray="2.4 1.8"/></g><path d="M2 12.2c1.7-1.6 3.1-1.6 4.7 0s3 1.6 4.6 0 3-1.6 4.7 0" />',
}
def ic(n,cls='',sz=None,style=''):
    s=f' style="{("width:%dpx;height:%dpx;"%(sz,sz) if sz else "")}{style}"'
    return f'<svg class="i {cls}" viewBox="0 0 16 16"{s}>{P[n]}</svg>'
def gl(n,extra=''):
    return f'<span class="glyph"><svg class="i" viewBox="0 0 18 16">{GLYPH[n]}</svg>{extra}</span>'
def dot(c): return f'<i class="dot" style="background:var(--tag-{c})"></i>'
def app(c): return f'<i class="appic" style="background:{c}"></i>'
def wrap(cap,html,w=None): return f'<div class="ab"><div class="cap">{cap}</div>{html}</div>'
def bd(inner,pad=28,extra=''): return f'<div class="backdrop" style="padding:{pad}px;{extra}">{inner}</div>'

def row(lead,t,sub,sel=False,badges='',cls='',chips=''):
    return f'<div class="row {"sel" if sel else ""} {cls}"><div class="lead">{lead}</div><div class="txt"><div class="p1">{t}</div><div class="p2">{sub}</div></div><div class="badges">{chips}{badges}</div></div>'
def thumb(a,b): return f'<div style="width:100%;height:100%;background:linear-gradient(135deg,{a},{b})"></div>'
def side(on='all',tags=True):
    def r(i,name,n,k=''):
        return f'<div class="srow {"on" if on==k else ""}">{ic(i)}<span>{name}</span><span class="n">{n}</span></div>'
    t=''.join(f'<div class="srow {"on" if on==k else ""}">{dot(c)}<span>{n}</span><span class="n">{m}</span></div>' for k,c,n,m in [('t1','blue','Invoices',12),('t2','green','Recipes',4),('t3','purple','Draft copy',7)])
    a=''.join(f'<div class="srow">{app(c)}<span>{n}</span><span class="n">{m}</span></div>' for c,n,m in [('oklch(0.62 0.15 250)','Safari',58),('oklch(0.6 0.12 150)','Notes',31),('oklch(0.55 0.17 300)','Xcode',22)])
    return ('<div class="side">'+r('clock','All Items',212,'all')+r('pin','Pinned',6,'pin')+
      '<h6>Types</h6>'+r('text','Text',104)+r('link','Links',41)+r('image','Images',28)+r('shot','Screenshots',19)+r('doc','Files',12)+r('color','Colors',8)+
      '<h6>Tags</h6>'+t+'<h6>Apps</h6>'+a+'</div>')
def top(q=None,mode='list',n=''):
    s = f'<span>{q}</span><span class="caret"></span>' if q else '<span class="caret"></span><span class="ph">Search clipboard history</span>'
    clr = f'<span class="clr">{ic("xc",sz=16)}</span>' if q else ''
    return (f'<div class="top"><div class="search">{ic("search")}{s}{clr}</div>'
      f'<div class="seg"><span class="{"on" if mode=="list" else ""}">{ic("list")}</span><span class="{"on" if mode=="grid" else ""}">{ic("grid")}</span></div>'
      f'<div class="btn-ghost">{ic("sort")}<span>Recent</span></div></div>')
def foot(copyonly=False,multi=False,n=None):
    if copyonly:
        return f'<div class="footer"><span class="warn">{ic("warn")}Press ⌘V to paste</span><span class="link-btn">Enable pasting</span><span class="sp"></span><span><kbd>⇧↩</kbd>Copy</span><span><kbd>esc</kbd>Close</span></div>'
    if multi:
        return f'<div class="footer"><span><b style="color:var(--t1)">3 selected</b></span><span><kbd>⇧↩</kbd>Copy</span><span><kbd>⌘⌫</kbd>Delete</span><span class="sp"></span><span><kbd>esc</kbd>Clear selection</span></div>'
    return '<div class="footer"><span><kbd>↩</kbd>Paste</span><span><kbd>⌥↩</kbd>Plain text</span><span><kbd>⇧↩</kbd>Copy</span><span><kbd>⌘Y</kbd>Preview</span><span class="sp"></span><span><kbd>esc</kbd>Close</span></div>'
def lib(listhtml,q=None,mode='list',foothtml=None,prev=None,sidebar=True):
    return (f'<div class="panel lib">{top(q,mode)}<div class="body">{side() if sidebar else ""}<div class="results">{listhtml}</div>{prev or ""}</div>{foothtml or foot()}</div>')

ROWS=[
 row(ic('text'),'Dinner at 7? I booked the corner table, the one by the window.','<span>Messages</span><span>·</span><span>2 min ago</span>',sel=True,badges=f'<span class="badge">⌘1</span>'),
 row(ic('link'),'swift.org/blog/swift-6-concurrency','<span>Safari</span><span>·</span><span>9 min ago</span>',badges='<span class="badge">⌘2</span>',chips=''),
 row(thumb('oklch(0.75 0.1 200)','oklch(0.55 0.12 260)'),'Screenshot 2026-11-16 at 09.41.22','<span>Screenshots</span><span>·</span><span>1,440 × 900</span><span>·</span><span>14 min ago</span>',badges='<span class="badge">⌘3</span>'),
 row(f'<i class="swatch" style="background:oklch(0.62 0.13 195)"></i>','#2A9D8F','<span>Color</span><span>·</span><span>Figma</span><span>·</span><span>31 min ago</span>',badges='<span class="badge">⌘4</span>'),
 row(ic('doc'),'Q4-invoice-final.pdf','<span>File</span><span>·</span><span>Finder</span><span>·</span><span>1 hr ago</span>',badges=f'{ic("pin",sz=13)}<span class="badge">⌘5</span>',chips=f'<span class="chip">{dot("blue")}Invoices</span>'),
 row(ic('text'),'func copy(_ item: ClipItem) async throws { … }','<span>Xcode</span><span>·</span><span>Today, 08:12</span>',badges=f'{ic("note",sz=13)}{ic("bolt",sz=13)}<span class="badge">⌘6</span>'),
 row(ic('link'),'Ink &amp; Salt — braised short ribs','<span>Safari</span><span>·</span><span>Yesterday</span>',badges='<span class="badge">⌘7</span>',chips=f'<span class="chip">{dot("green")}Recipes</span>'),
 row(ic('text'),'Meeting notes — 5 items, bundled','<span>Notes</span><span>·</span><span>Yesterday</span>',badges='<span class="badge">⌘8</span>'),
 row(ic('text'),'Reminder: renew the domain before the 20th','<span>Reminders</span><span>·</span><span>Mon</span>',badges='<span class="badge">⌘9</span>'),
]
def listpane(rows): return '<div class="list">'+''.join(rows)+'</div>'
PREV_TXT=('<div class="prev"><div class="content">Dinner at 7? I booked the corner table, the one by the window. Bring the printout of the menu if you still have it, and tell Ana we are on the second floor.</div>'
 '<dl class="meta"><dt>Kind</dt><dd>Text</dd><dt>Source</dt><dd>Messages</dd><dt>Copied</dt><dd>Nov 16, 2026, 09:52</dd><dt>First copied</dt><dd>Nov 14, 2026, 18:03</dd><dt>Times copied</dt><dd>3</dd><dt>Times pasted</dt><dd>1</dd><dt>Size</dt><dd>168 characters</dd></dl></div>')
PREV_IMG=('<div class="prev"><div class="content" style="padding:0;height:150px">'+thumb('oklch(0.75 0.1 200)','oklch(0.55 0.12 260)')+'</div>'
 '<dl class="meta"><dt>Kind</dt><dd>Screenshot</dd><dt>Source</dt><dd>Screenshots</dd><dt>Copied</dt><dd>Nov 16, 2026, 09:41</dd><dt>First copied</dt><dd>Nov 16, 2026, 09:41</dd><dt>Times copied</dt><dd>1</dd><dt>Times pasted</dt><dd>0</dd><dt>Size</dt><dd>412 KB</dd><dt>Pixel size</dt><dd>1,440 × 900</dd></dl></div>')
def cell(inner,cls='',sel=False,src='Safari',img=False):
    return f'<div class="cell {"img" if img else ""} {"sel" if sel else ""}">{inner}<div class="cb"><span class="src">{app("oklch(0.62 0.15 250)")}{src}</span></div></div>'
GRID='<div class="grid">'+''.join([
 cell('Dinner at 7? I booked the corner table by the window.',sel=True,src='Messages'),
 cell('<div class="ph2">'+thumb('oklch(0.75 0.1 200)','oklch(0.55 0.12 260)')+'</div>',img=True,src='Screenshots'),
 cell('<div style="font-size:11px;color:var(--accent-text);font-weight:600">swift.org</div>swift-6-concurrency'),
 cell('<div style="flex:1;border-radius:6px;background:oklch(0.62 0.13 195);margin-bottom:22px"></div>',src='Figma'),
 cell(f'<div style="display:flex;justify-content:center;padding:10px 0;color:var(--t2)">{ic("doc",sz=34)}</div>Q4-invoice-final.pdf',src='Finder'),
 cell('func copy(_ item: ClipItem) async throws',src='Xcode'),
 cell('<div class="ph2">'+thumb('oklch(0.8 0.08 80)','oklch(0.6 0.12 30)')+'</div>',img=True,src='Preview'),
 cell('Reminder: renew the domain before the 20th',src='Reminders'),
])+'</div>'

def sheet(name,title,items):
    html=f'<!doctype html><meta charset=utf-8><title>{title}</title><link rel=stylesheet href=tokens.css><link rel=stylesheet href=components.css><body><div class=sheet>{"".join(items)}</div><script>if(location.search.includes("dark"))document.body.classList.add("dark"),document.documentElement.classList.add("dark");addEventListener("load",()=>{{const e=document.createElement("i");e.id="hh";e.textContent="H="+Math.ceil(document.querySelector(".sheet").getBoundingClientRect().bottom);document.body.appendChild(e)}})</script>'
    open(os.path.join(D,name+'.html'),'w').write(html)

# 01 Library
sheet('01-library','Library',[
 wrap('Library — list, preview closed (760 × 480)',bd(lib(listpane(ROWS)))),
 wrap('Library — list, preview open (sidebar 168 + results 312 + preview 280)',bd(lib(listpane(ROWS[:8]).replace('class="list"','class="list" style="width:312px"'),prev=PREV_TXT,q='dinner'))) ,
 wrap('Library — screenshot preview',bd(lib(listpane([ROWS[2]]+ROWS[0:1]+ROWS[3:8]),prev=PREV_IMG))),
 wrap('Library — grid (120 pt cells)',bd(lib(GRID,mode='grid'))),
])
# fix: second panel results width handled by flex

# 02 States
def stt(i,h,p,btn=''): return f'<div class="state">{ic(i,sz=30)}<h3>{h}</h3><p>{p}</p>{btn}</div>'
errst=('<div class="state"><span style="color:var(--err)">'+ic('warn',sz=30)+'</span><h3>History unavailable</h3><p>Couldn’t read your history. Try again.</p><span class="btn">Retry</span><div class="err-inline" style="margin-top:2px;color:var(--t2)">STO-DB-004</div></div>')
multi=[ROWS[0].replace('class="row ','class="row multi '),ROWS[1].replace('class="row ','class="row multi '),ROWS[2].replace('class="row ','class="row multi ')]+ROWS[3:8]
sheet('02-library-states','Library states',[
 wrap('Empty history',bd(lib(stt('clock','Nothing copied yet','Copy something and it appears here. Press ⌃⌘V any time to open this panel.'),foothtml=foot(),sidebar=False))),
 wrap('No results',bd(lib(stt('search','No matches for “zebra”','Check the spelling, or clear the search to see everything.','<span class="btn sm">Clear Search</span>'),q='zebra',sidebar=True))),
 wrap('Database error, inline with Retry (STO-DB-004)',bd(lib(errst,sidebar=False))),
 wrap('Copy-only mode (no Accessibility permission)',bd(lib(listpane(ROWS),foothtml=foot(copyonly=True)))),
 wrap('Multi-select, Return disabled (3 selected)',bd(lib(listpane(multi),foothtml=foot(multi=True)))),
])
# 03 Organize
def tagpop():
    rs=''.join(f'<div class="trow {h}"><span class="chk">{c}</span>{dot(col)}<span>{n}</span><span class="n">{m}</span></div>' for c,col,n,m,h in [(ic('check',sz=14),'blue','Invoices','','hl'),(ic('minus',sz=14),'green','Recipes','2 of 3',''),('','purple','Draft copy','','')])
    return f'<div class="pop" style="width:240px"><div class="field focus"><span class="ph" style="color:var(--t1)">inv</span><span class="caret" style="width:1.5px;height:16px;background:var(--accent)"></span></div>{rs}<div class="trow">{ic("plus",sz=14)}<span>Create “inv”</span></div></div>'
def notepop(bad=False):
    cnt='2,014 / 2,000' if bad else '86 / 2,000'
    err='<div class="err-inline">'+ic('warn')+'<span>Notes can be up to 2,000 characters.</span></div>' if bad else ''
    return f'<div class="pop" style="width:300px"><div class="field area {"bad" if bad else "focus"}">Waiting on the vendor to confirm the revised total before I send this.</div><div style="display:flex;justify-content:space-between;font-size:11px;color:{"var(--err)" if bad else "var(--t2)"}"><span>Note</span><span>{cnt}</span></div>{err}<div class="btnrow"><span class="btn sm">Cancel</span><span class="btn sm pri">Save</span></div></div>'
def trigpop(bad=False):
    b='<div class="err-inline">'+ic('warn')+'<span>This shortcut is already used by “Reply sign-off.” Choose another.</span></div>' if bad else ''
    return (f'<div class="pop" style="width:340px"><div class="form" style="grid-template-columns:90px 1fr;gap:10px"><span class="l">Shortcut</span><div class="v"><span class="recorder {"bad" if bad else ""}">⌃⌥1</span>{b}</div>'
     f'<span class="l">Trigger text</span><div class="v"><div class="field focus" style="width:100%">;sig</div></div></div>'
     f'<div class="help">Triggers fire when you type the text followed by a space. Variables: {{date}}, {{time}}, {{clipboard}}.</div><div class="btnrow"><span class="btn sm">Cancel</span><span class="btn sm pri">Save</span></div></div>')
def ctx(items):
    h=''
    for it in items:
        if it=='-': h+='<div class="msep"></div>'
        else:
            lab,k,*f=it; cls='on' if 'on' in f else ('dis' if 'dis' in f else '')
            h+=f'<div class="mi {cls}">{lab}<span class="k">{k}</span></div>'
    return f'<div class="menu">{h}</div>'
CTX=[('Paste','↩','on'),('Paste as Plain Text','⌥↩'),('Copy','⇧↩'),('Preview','⌘Y'),'-',('Pin','⌘P'),('Tags…','⌘T'),('Note…','⌘N'),('Edit…','⌘E'),('Shortcut and Trigger…','⌘K'),('Ungroup','⌘⇧U','dis'),'-',('Reveal in Finder','⌘R'),'-',('Delete','⌘⌫')]
SORT=[('Recent','⌘S'),('Oldest',''),('Most Used',''),('A to Z','')]
sortm='<div class="menu">'+''.join(f'<div class="mi {"on" if i==0 else ""}">{ic("check",cls="ck") if i==0 else ""}{n}<span class="k">{k}</span></div>' for i,(n,k) in enumerate(SORT))+'</div>'
tagctx=('<div class="menu" style="min-width:190px"><div class="mi">Rename…</div><div class="msep"></div>'+''.join(f'<div class="mi">{ic("check",cls="ck") if c=="blue" else ""}<i class="dot" style="background:var(--tag-{c});margin-right:2px"></i>{c.capitalize()}</div>' for c in ['red','orange','yellow','green','blue','purple','pink','gray'])+'<div class="msep"></div><div class="mi">Delete Tag…</div></div>')
sheet('03-organize','Organize',[
 wrap('Tag popover (checked, mixed, create row)',bd(tagpop(),extra='padding:28px 40px')),
 wrap('Note popover',bd(notepop())),
 wrap('Note popover, over limit (ORG-VAL-001 inline)',bd(notepop(True))),
 wrap('Shortcut and trigger editor',bd(trigpop())),
 wrap('Shortcut and trigger editor, conflict',bd(trigpop(True))),
 wrap('Item context menu (FR-003-22 order)',bd(ctx(CTX))),
 wrap('Sort menu',bd(sortm)),
 wrap('Sidebar tag context menu',bd(tagctx)),
])
# 04 Editor and alerts
def alert(title,msg,btns,mark='alert'):
    b=''.join(f'<span class="btn {c}">{t}</span>' for t,c in btns)
    return f'<div class="alert"><div class="appmark" style="width:48px;height:48px;border-radius:12px;background:var(--accent);display:flex;align-items:center;justify-content:center;color:#fff">{GLYPHBIG}</div><h4>{title}</h4><p>{msg}</p><div class="acts">{b}</div></div>'
GLYPHBIG='<svg class="i" viewBox="0 0 18 16" style="width:30px;height:30px">'+GLYPH['active'].replace('currentColor','#fff')+'</svg>'
editor=('<div class="panel lib"><div class="top"><div class="search" style="font-size:15px;font-weight:600">'+ic('text')+'Edit text</div></div><div style="padding:14px 16px;display:flex;flex-direction:column;gap:10px;flex:1">'
 '<div class="err-inline" style="color:var(--t2)">'+ic('info')+'<span>Saving removes formatting. The edited item becomes plain text.</span></div>'
 '<div class="field area focus" style="flex:1;font-size:13.5px">Dinner at 7? I booked the corner table, the one by the window.</div></div>'
 '<div class="footer"><span><kbd>⌘↩</kbd>Save</span><span><kbd>esc</kbd>Cancel</span><span class="sp"></span><span>63 characters</span></div></div>')
sheet('04-editor-alerts','Editor and alerts',[
 wrap('In-panel text editor',bd(editor)),
 wrap('Delete item',bd(alert('Delete this item?','This permanently removes it from your history.',[('Delete','dst pri'),('Cancel','')]))),
 wrap('Ungroup bundle',bd(alert('Ungroup 5 items?','They become separate items in your history.',[('Ungroup','pri'),('Cancel','')]))),
 wrap('Delete tag',bd(alert('Delete tag “Invoices”?','Remove tag “Invoices” from 12 items? The items stay.',[('Delete Tag','dst pri'),('Cancel','')]))),
])
# 05 Shelf
def card(i,t,sel=False,pin=False,flash=False,v=False,extra=''):
    ico=thumb('oklch(0.75 0.1 200)','oklch(0.55 0.12 260)') if i=='img' else ic(i)
    pb=f'<span class="pinb">{ic("pin",sz=13)}</span>' if pin else ''
    return f'<div class="card {"v" if v else ""} {"sel" if sel else ""} {"flash" if flash else ""}"><div class="ico">{ico}</div><div class="ct">{t}</div>{pb}{extra}</div>'
def shelf(cards,cls='',close=False,h1='Pinned',h2='Recent',n1=0,extra=''):
    c=f'<span class="close">{ic("x",sz=12)}</span>' if close else ''
    return f'<div class="shelf {cls}">{c}{extra}{cards}</div>'
pinned=[('doc','Q4-invoice-final.pdf',0,1),('text','Thanks for reaching out, I’ll reply by Friday.',0,1)]
recent=[('text','Dinner at 7? I booked the corner table.',1,0),('img','Screenshot 09.41.22',0,0),('link','swift.org/blog/swift-6-concurrency',0,0),('text','Reminder: renew the domain',0,0)]
def cardlist(sel=False):
    return f'<h6>{ic("pin",sz=12)}Pinned</h6>'+''.join(card(i,t,pin=True) for i,t,_,_ in pinned)+'<h6>Recent</h6>'+''.join(card(i,t,sel=(s and sel)) for i,t,s,_ in recent)
sheet('05-shelf','Shelf',[
 wrap('Right edge, transient (hover reveal)',bd(shelf(cardlist()))),
 wrap('Right edge, drop highlight (system accent)',bd(shelf('<div class="dropzone">'+ic('plus',sz=14)+'Drop to pin</div>'+cardlist(),cls='drop'))),
 wrap('Sticky, close button and selection',bd(shelf(cardlist(sel=True),close=True))),
 wrap('Empty',bd(shelf('<div class="state" style="padding:40px 12px">'+ic('edge',sz=28)+'<h3>Shelf is empty</h3><p>Copy something, or drag an item here to pin it.</p></div>'))),
 wrap('Shelf context menu',bd(ctx([('Paste','↩','on'),('Paste as Plain Text','⌥↩'),('Copy','⇧↩'),'-',('Unpin','⌘P'),'-',('Delete','⌘⌫')]))),
 wrap('Bottom strip (140 pt, 112 pt cards)',bd('<div class="shelf bottom"><div class="strip">'+''.join(card(i,t,v=True,sel=(s==1 and i=="text" and "Dinner" in t),pin=bool(p)) for i,t,s,p in pinned+recent)+'</div></div>',pad=16)),
 wrap('menuBar placement (280 pt, under the icon)','<div class="backdrop" style="padding:0;width:560px"><div class="mbar" style="width:100%;border-radius:8px 8px 0 0">'+gl('active')+'<span>Mon 9:52</span></div><div style="padding:0 20px 24px;display:flex;justify-content:flex-end"><div class="shelf" style="margin-right:56px">'+cardlist()+'</div></div></div>'),
])
# 06 Settings
def win(title,active,pane,w=560):
    tabs=[('gear','General'),('kbd','Shortcuts'),('bolt','Triggers'),('hand','Privacy'),('disk','Storage'),('info','About')]
    t=''.join(f'<div class="tab {"on" if n==active else ""}">{ic(i)}<span>{n}</span></div>' for i,n in tabs)
    return f'<div class="win" style="width:{w}px"><div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><div class="ttl">{title}</div></div><div class="tabs">{t}</div><div class="pane">{pane}</div></div>'
def F(*rows): return '<div class="form">'+''.join(rows)+'</div>'
def fr(l,v,top=False): return f'<div class="l {"top" if top else ""}">{l}</div><div class="v">{v}</div>'
def sw(on=True): return f'<span class="switch {"on" if on else ""}"></span>'
def popup(t): return f'<span class="popup"><span>{t}</span>{ic("updn",sz=12)}</span>'
general=F(fr('Startup',f'<div class="row2">{sw()}<span>Open Flotsam at login</span></div>'),
 fr('Menu bar',f'<div class="row2">{sw()}<span>Show Flotsam in the menu bar</span></div>'),
 fr('History',f'<div class="row2">{sw()}<span>Record clipboard history</span></div><div class="help">Turn off to pause. Existing items stay.</div>',True),
 '<div class="hr"></div>',
 fr('Paste behavior',f'<div class="row2">{sw()}<span>Paste after choosing an item</span></div><div class="row2">{sw(False)}<span>Always paste as plain text</span></div>',True),
 fr('Sound',f'<div class="row2">{sw(False)}<span>Play a sound when copying</span></div>'),
 fr('Library layout',f'{popup("List")}'))
shortcuts=F(fr('Open Library','<span class="recorder">⌃⌘V</span>'),
 fr('Open Shelf','<span class="recorder rec">Type shortcut</span><div class="help">Press the keys you want. Esc cancels.</div>',True),
 fr('Pause recording','<span class="recorder" style="color:var(--t2)">None</span>'),
 fr('Paste as plain text','<span class="recorder" style="color:var(--t2)">None</span>'),
 '<div class="hr"></div>',
 f'<div></div><div class="v"><span class="btn sm">Reset Defaults</span></div>')
def lbox(rows,sel=None):
    r=''.join(f'<div class="lrow {"sel" if i==sel else ""}">{a}<span>{b}</span><span class="sub" style="{"color:var(--on-sel-2)" if i==sel else ""}">{c}</span></div>' for i,(a,b,c) in enumerate(rows))
    return f'<div class="listbox">{r}<div class="lbar"><span class="sq">{ic("plus",sz=14)}</span><span class="sq">{ic("minus",sz=14)}</span></div></div>'
triggers=(f'<div style="display:flex;align-items:center;gap:10px"><b style="font-size:13px">Triggers</b><span class="help" style="flex:1">Type the text and a space to paste an item.</span>{sw()}</div>'
 +lbox([('',';sig','Thanks for reaching out, I’ll reply by Friday.'),('',';addr','12 Marsh Lane, Beaufort'),('',';ok','Looks good to me, ship it.')],sel=0)
 +'<div class="status">'+ic('warn',cls='',sz=16,style='color:var(--warn)')+'<span style="font-size:12px">Triggers need Input Monitoring. Open System Settings to allow it.</span><span class="btn sm" style="margin-left:auto">Open Settings</span></div>')
def prmrow(n,ok,help_,btn='Open System Settings'):
    pill=f'<span class="pill ok">{ic("check",sz=11)}Allowed</span>' if ok else f'<span class="pill no">{ic("warn",sz=11)}Not allowed</span>'
    b='' if ok else f'<span class="btn sm" style="margin-left:auto">{btn}</span>'
    return f'<div class="status" style="flex-direction:column;align-items:flex-start;gap:4px"><div style="display:flex;gap:8px;align-items:center;width:100%"><b>{n}</b>{pill}{b}</div><div class="help">{help_}</div></div>'
privacy=(prmrow('Accessibility',True,'Lets Flotsam paste into the app you are using.')+prmrow('Input Monitoring',False,'Lets triggers notice the text you type. Flotsam never stores keystrokes.')+prmrow('Paste from Other Apps',False,'macOS 15.4 and later asks before apps read the clipboard. Choose Always Allow.')
 +f'<div class="form" style="margin-top:2px">{fr("Ignored apps",lbox([(app("oklch(0.5 0.1 30)"),"Keychain Access",""),(app("oklch(0.55 0.12 250)"),"Passwords","")]),True)}</div><div style="display:flex;gap:8px"><span class="btn sm">Reset Defaults</span></div>')
storage=F(fr('Keep history for',popup('1 year')+'<div class="help">Pinned items and items with a shortcut are always kept.</div>',True),
 fr('Maximum size',popup('2 GB')),
 fr('Used','<b>312 MB</b><span class="help">Library 188 MB · Screenshots 124 MB</span>'.replace('<span','<div').replace('</span>','</div>')),
 '<div class="hr"></div>',
 f'<div></div><div class="v"><span class="btn sm dst">Clear History…</span></div>')
about=('<div style="display:flex;flex-direction:column;align-items:center;gap:6px;padding:6px 0"><div style="width:72px;height:72px;border-radius:17px;background:var(--accent);display:flex;align-items:center;justify-content:center">'+GLYPHBIG.replace('30px','44px').replace('30px','44px')+'</div><b style="font:700 18px var(--font)">Flotsam</b><span class="help">Version 1.0 (1)</span><span class="help" style="max-width:340px;text-align:center">Free, open source clipboard history. Everything stays on your Mac.</span><div style="display:flex;gap:8px;margin-top:8px"><span class="btn sm">View Source</span><span class="btn sm">Licence</span><span class="btn sm">Diagnostics</span></div></div>')
sheetwin=lambda inner:f'<div class="msheet">{inner}</div>'
clear=sheetwin('<h4>Clear all history?</h4><div class="help" style="font-size:12.5px">This permanently deletes 212 items. This can’t be undone.</div><div class="btnrow"><span class="btn">Cancel</span><span class="btn pri dst">Delete All</span></div>'.replace('btn pri dst','btn dst pri'))
shorten=alert('Shorten history?','This permanently deletes 41 items older than 3 months. Pinned items and items with a shortcut are kept.',[('Delete Items','dst pri'),('Cancel','')])
resetapps=alert('Reset ignored apps?','Replace your list with the default apps?',[('Replace','pri'),('Cancel','')])
licence=sheetwin('<h4>Licence</h4><div class="field area" style="min-height:120px;font:11px/1.45 var(--mono);color:var(--t2)">MIT License<br><br>Copyright (c) 2026 Flotsam contributors<br><br>Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files…</div><div class="btnrow"><span class="btn pri">Done</span></div>')
sheet('06-settings','Settings',[
 wrap('General',bd(win('General','General',general),pad=20)),
 wrap('Shortcuts (recording a shortcut)',bd(win('Shortcuts','Shortcuts',shortcuts),pad=20)),
 wrap('Triggers',bd(win('Triggers','Triggers',triggers),pad=20)),
 wrap('Privacy (includes 15.4+ row)',bd(win('Privacy','Privacy',privacy),pad=20)),
 wrap('Storage',bd(win('Storage','Storage',storage),pad=20)),
 wrap('About',bd(win('About','About',about),pad=20)),
 wrap('Clear History sheet',bd(clear)),
 wrap('Shorten history alert',bd(shorten)),
 wrap('Reset ignored apps alert',bd(resetapps)),
 wrap('Licence sheet',bd(licence)),
])
# 07 Onboarding
def onb(step,icon,h,p,ctl='',skip='Skip',primary='Continue',stakes=''):
    dots=''.join(f'<i class="{"on" if i==step else ""}"></i>' for i in range(1,9))
    st=f'<div class="stakes">{stakes}</div>' if stakes else ''
    return (f'<div class="win onb" style="width:520px"><div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><div class="ttl">Welcome to Flotsam</div></div>'
      f'<div class="stage"><div class="hero">{ic(icon)}</div><h2>{h}</h2><div class="lead-p">{p}</div>{st}<div class="ctl">{ctl}</div></div>'
      f'<div class="nav"><span class="btn sm" style="visibility:{"hidden" if step==1 else "visible"}">Back</span><div class="dots">{dots}</div><span class="btn sm">{skip}</span><span class="btn pri">{primary}</span></div></div>')
ON=[
 onb(1,'swoosh','Everything you copy, within reach','Flotsam keeps your clipboard and screenshot history on this Mac. Nothing leaves it.',skip='Skip Setup',primary='Get Started'),
 onb(2,'paste','Allow Paste from Other Apps','macOS 15.4 and later asks before apps read the clipboard. Choose Always Allow so Flotsam can save what you copy.',ctl='<span class="btn">Open Settings</span>',stakes='Skip this and Flotsam can’t record new copies.'),
 onb(3,'hand','Allow Accessibility','Accessibility lets Flotsam paste into the app you are using.',ctl='<div class="status" style="width:300px;justify-content:center"><span class="pill no">'+ic('warn',sz=11)+'Not allowed</span></div><span class="btn">Open Settings</span>',stakes='Skip this and Flotsam copies only. You press ⌘V yourself.'),
 onb(4,'kbd','Add triggers (optional)','Input Monitoring lets Flotsam notice the text you type to expand triggers. It never stores keystrokes.',ctl='<span class="btn">Open Settings</span>',skip='Not Now',stakes='You can turn this on later in Settings.'),
 onb(5,'shot','Pick up screenshots','Choose the folder where macOS saves screenshots. Flotsam adds new ones to your history.',ctl='<div class="field" style="width:300px">'+ic('folder')+'<span>~/Desktop</span></div><span class="btn">Choose Folder…</span>'),
 onb(6,'search','Open Library with a shortcut','Press this shortcut any time to search your history.',ctl='<span class="recorder" style="min-width:180px;height:32px;font-size:15px">⌃⌘V</span><span class="help">Click to record a different shortcut.</span>'),
 onb(7,'login','Open Flotsam at login','Flotsam stays in the menu bar so your history is always ready.',ctl='<div class="row2" style="display:flex;gap:8px;align-items:center">'+sw()+'<span>Open at login</span></div>'),
 onb(8,'check','You’re ready','Copy something, then press ⌃⌘V. Flotsam lives in your menu bar.',skip='',primary='Open Library'),
]
sheet('07-onboarding','Onboarding',[wrap(f'Step {i+1} of 8',bd(o,pad=18)) for i,o in enumerate(ON)])
# 08 Menu bar + feedback
def mbar(g,extra=''): return f'<div class="mbar">{gl(g,extra)}<span>Mon 9:52</span></div>'
MENU=[('Open Library','⌃⌘V','on'),('Open Shelf',''),'-',('Pause Recording',''),('Notices','›'),'-',('Settings…','⌘,'),('About Flotsam',''),('Quit Flotsam','⌘Q')]
NOT=['<div class="menu" style="min-width:300px"><div class="mi dis" style="padding-left:12px">Notices</div>',
 '<div class="mi" style="height:38px;flex-direction:column;align-items:flex-start;justify-content:center;gap:0;padding-left:12px"><span>Couldn’t save a screenshot</span><span class="ninfo">CAP-IO-002</span></div>',
 '<div class="mi" style="height:38px;flex-direction:column;align-items:flex-start;justify-content:center;gap:0;padding-left:12px"><span>Pasting is off. Flotsam copies only.</span><span class="ninfo">SET-PRM-001</span></div>',
 '<div class="msep"></div><div class="mi" style="padding-left:12px">Dismiss All</div></div>']
glyphs=''.join(f'<div style="display:flex;flex-direction:column;align-items:center;gap:6px;width:100px">{mbar_}<span class="ninfo" style="color:inherit">{lab}</span></div>' for mbar_,lab in [(f'<div class="mbar" style="width:80px;justify-content:center">{gl("active")}</div>','Active'),(f'<div class="mbar" style="width:80px;justify-content:center">{gl("paused")}</div>','Paused'),(f'<div class="mbar" style="width:80px;justify-content:center">{gl("curated")}</div>','Curated'),(f'<div class="mbar" style="width:80px;justify-content:center">{gl("active",chr(60)+"i class=wd></i>")}</div>','Warning dot')])
hud=lambda i,c,t:f'<div class="hud"><span class="{c}">{ic(i)}</span><span>{t}</span></div>'
sheet('08-menubar-feedback','Menu bar and feedback',[
 wrap('Menu-bar icon states (glyph shape differs; VoiceOver label per state)',bd(f'<div style="display:flex;gap:14px;color:var(--t1)">{glyphs}</div>')),
 wrap('Menu-bar menu',bd(ctx(MENU))),
 wrap('Notices submenu',bd(''.join(NOT))),
 wrap('HUD (top-centre of pointer screen, 2.5 s)',bd('<div style="display:flex;flex-direction:column;gap:10px;align-items:flex-start">'+hud('paste','g','Pasted “Dinner at 7? I booked…”')+hud('pause','w','Recording paused')+hud('warn','w','Pasting is off. Press ⌘V to paste.')+hud('xc','e','Couldn’t read the clipboard. Copy it again.')+'</div>')),
 wrap('Inline validation (field level)',bd('<div class="pop nocaret" style="width:300px"><div class="field bad"><span>;sig</span></div><div class="err-inline">'+ic('warn')+'<span>Trigger text is already used by “Email sign-off.” Choose different text.</span></div></div>')),
 wrap('Fatal alert (database cannot open)',bd(alert('Flotsam can’t open its history','Flotsam can’t open its history after an update. Your data is untouched; reinstall the previous version or reveal the data folder.',[('Quit Flotsam','pri'),('Show Folder','')]))),
])
print('ok')
