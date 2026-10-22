const CONFIG=window.PD_CONFIG||{url:'',key:''};
const $=s=>document.querySelector(s);let sb=null,R={me:{},t:[]},tab='tk',PH=null;
try{if(CONFIG.url&&CONFIG.key)sb=supabase.createClient(CONFIG.url,CONFIG.key)}catch(e){}
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),m2=n=>'$'+(+n||0).toFixed(2),
T=(m,er)=>{const t=$('#ts');t.textContent=m;t.className='on'+(er?' er':'');clearTimeout(T.i);T.i=setTimeout(()=>t.className='',3400)},
sha=async b=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',b))].map(x=>x.toString(16).padStart(2,'0')).join(''),
loc=()=>new Promise(r=>navigator.geolocation?navigator.geolocation.getCurrentPosition(p=>r({a:p.coords.latitude,o:p.coords.longitude}),()=>r(null),{enableHighAccuracy:true,timeout:12000,maximumAge:0}):r(null)),
lab=d=>d.status=='delivered'?(d.cleared||d.risk_score<30?['Verified','ok']:d.risk_score<60?['Under review','wn']:['Flagged','er']):d.status=='failed'?['Failed','er']:d.status=='arrived'?['At the door','wn']:['To do',''],
bg=d=>`<span class="b ${lab(d)[1]}">${lab(d)[0]}</span>`,
trust=()=>{const x=R.t.filter(d=>['delivered','failed'].includes(d.status)&&!d.cleared).slice(0,15);return x.length?Math.max(0,Math.round(100-x.reduce((a,d)=>a+d.risk_score,0)/x.length)):100},
em=(t,p)=>`<div class="em"><h3 style="margin-top:0">${t}</h3><p>${p}</p></div>`,
row=d=>`<div class="rw" data-a="dt" data-i="${d.id}"><div><b>${esc(d.address)}</b><small>${esc(d.recipient_name||'Recipient')}${+d.cod_amount?' · collect '+m2(d.cod_amount):''}</small></div>${bg(d)}</div>`;
let API;
if(sb)API={
 async load(){const u=(await sb.auth.getUser()).data.user,p=await sb.from('profiles').select('full_name,vehicle,status').eq('id',u.id).single();if(p.error)throw p.error;R.me={...p.data,id:u.id};await API.refresh()},
 async refresh(){const {data,error}=await sb.rpc('rider_tasks');if(error)throw error;R.t=data},
 async arrive(id,pos){const {data,error}=await sb.rpc('rider_arrive',{p_delivery:id,p_lat:pos?pos.a:null,p_lng:pos?pos.o:null});if(error)throw error;return data},
 async complete(id,v){const path=`${R.me.id}/${id}-${Date.now()}.jpg`,up=await sb.storage.from('delivery-photos').upload(path,v.p.blob,{contentType:'image/jpeg'});if(up.error)throw up.error;
  const {data,error}=await sb.rpc('rider_complete',{p_delivery:id,p_otp:v.otp,p_lat:v.pos?v.pos.a:null,p_lng:v.pos?v.pos.o:null,p_photo_path:path,p_photo_hash:v.p.hash,p_cod:v.cod});if(error)throw error;return data},
 async gone(id){const {data,error}=await sb.rpc('rider_unavailable',{p_delivery:id});if(error)throw error;return data}};
else{const id=()=>Math.random().toString(36).slice(2,10),H=new Set(),mk=(ad,n,cod,st,risk=0,fl=[])=>({id:id(),tracking_code:id().toUpperCase(),address:ad,recipient_name:n,recipient_phone:'+15550100',cod_amount:cod,cod_collected:st=='delivered'?cod:null,status:st,risk_score:risk,flags:fl,cleared:false,created_at:new Date(Date.now()-36e5).toISOString()});
 API={async load(){if(R.t.length)return;R={me:{id:'me',full_name:'Bola Adeyemi',vehicle:'Motorbike',status:'active'},t:[mk('14 Palm Ave','Amaka Obi',185,'assigned'),mk('9 Mill Rd','Sam Reyes',0,'assigned'),mk('22 Harbor St','Priya Nair',60,'assigned'),mk('5 Cedar Way','Leo Park',25,'delivered'),mk('31 Ridge Rd','Jon Ames',0,'delivered'),mk('7 Quay St','Amara Eze',120,'delivered',35,[{w:35,t:'Completed 310 m from the drop-off pin'}])]}},
 async refresh(){},
 async arrive(i){const d=R.t.find(x=>x.id==i);await new Promise(r=>setTimeout(r,900));if(!d.far){d.far=1;return{ok:false,distance:240,radius:100}}d.status='arrived';d.t0=Date.now();return{ok:true}},
 async complete(i,v){const d=R.t.find(x=>x.id==i);if(v.otp!='4821'){d.at=(d.at||0)+1;if(d.at>=3){Object.assign(d,{status:'failed',risk_score:30,flags:[{w:30,t:'Handoff code entered wrong 3 times'}]});return{ok:false,locked:true}}return{ok:false,attempts_left:3-d.at}}
  const f=[];if(Date.now()-d.t0<2e4)f.push({w:15,t:'Completed less than 20 seconds after arrival'});if(H.has(v.p.hash))f.push({w:40,t:'This photo was already used on another delivery'});H.add(v.p.hash);
  if(+d.cod_amount&&+d.cod_amount!=v.cod)f.push({w:30,t:`Cash mismatch: expected ${m2(d.cod_amount)}, collected ${m2(v.cod)}`});if(d.at)f.push({w:d.at*5,t:`${d.at} wrong code attempt${d.at>1?'s':''}`});
  Object.assign(d,{status:'delivered',flags:f,risk_score:Math.min(100,f.reduce((a,x)=>a+x.w,0)),cod_collected:v.cod});return{ok:true}},
 async gone(i){Object.assign(R.t.find(x=>x.id==i),{status:'failed',risk_score:5,flags:[{w:5,t:'Recipient unavailable'}]});return{ok:true}}}}
const V={
tk(){const a=R.t.filter(x=>['assigned','arrived'].includes(x.status)),c=R.t.filter(x=>['delivered','failed'].includes(x.status)).slice(0,8);
 return`<p>Hi ${esc((R.me.full_name||'').split(' ')[0])}</p><div class="hd"><h2>Your deliveries</h2><span class="b ${trust()<60?'er':'ok'}">Trust ${trust()}</span></div>`+(a.map(row).join('')||em('Nothing to deliver right now','New deliveries assigned to you will show up here.'))+(c.length?'<h3>Recent</h3>'+c.map(row).join(''):'')},
pf(){const t=trust(),f=R.t.filter(x=>(x.flags||[]).length&&['delivered','failed'].includes(x.status)).slice(0,5);
 return`<h2 style="margin-bottom:16px">Profile</h2><div class="cd" style="text-align:center"><svg width="140" height="140" viewBox="0 0 100 100"><circle cx="50" cy="50" r="42" fill="none" stroke="var(--ln)" stroke-width="8"/><circle class="tr" cx="50" cy="50" r="42" fill="none" stroke="${t<60?'var(--er)':t<80?'var(--wn)':'var(--gr)'}" stroke-width="8" stroke-linecap="round" stroke-dasharray="264" stroke-dashoffset="${264*(1-t/100)}" transform="rotate(-90 50 50)"/><text x="50" y="58" text-anchor="middle" fill="currentColor" font-size="26" font-weight="800">${t}</text></svg><div><b>${esc(R.me.full_name)}</b></div><p>${esc(R.me.vehicle||'No vehicle listed')} · trust score from your last 15 deliveries</p></div>
 <h3>What we noticed</h3>`+(f.length?f.map(d=>`<div class="cd"><b>${esc(d.address)}</b><ul>${d.flags.map(x=>`<li>${esc(x.t)}</li>`).join('')}</ul></div>`).join(''):'<p>Nothing flagged on your recent deliveries.</p>')+(sb?'<button class="btn" style="background:var(--sf);border:2px solid var(--ink)" data-a="out">Sign out</button>':'')}};
function render(an){const tb=[['tk','Tasks'],['pf','Profile']];$('#app').innerHTML=`<main class="main${an?' an':''}">${sb?'':'<div class="pv">Preview mode: sample deliveries, nothing is saved. The first check-in simulates being too far away.</div>'}${V[tab]()}</main><nav class="nav">${tb.map(t=>`<button data-a="tab" data-i="${t[0]}" class="${t[0]==tab?'on':''}">${t[1]}</button>`).join('')}</nav>`}
const dlg=$('#dlg'),show=h=>{$('#dc').innerHTML=h;dlg.open||dlg.showModal()},shake=()=>{dlg.classList.add('sk');setTimeout(()=>dlg.classList.remove('sk'),400)};
function sheet(id){const d=R.t.find(x=>x.id==id),hd=`<h2>${esc(d.address)}</h2><p>${esc(d.recipient_name||'Recipient')}${d.recipient_phone?` · <a href="tel:${esc(d.recipient_phone)}">${esc(d.recipient_phone)}</a>`:''}</p>${+d.cod_amount?`<p style="margin-top:8px">Collect <b style="color:var(--ink)">${m2(d.cod_amount)}</b> in cash</p>`:''}`;
 if(d.status=='assigned')return show(hd+`<p style="margin-top:14px">When you're at the door, check in. Your phone's location has to be at the drop-off.</p><button class="btn" data-a="arr" data-i="${d.id}">I've arrived</button>`);
 if(d.status=='arrived')return show(hd+`<label for="ot">Recipient's 4-digit code</label><input id="ot" class="otp" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="one-time-code" placeholder="····">${sb?'':'<p class="hint">Preview: the code is 4821.</p>'}<label>Photo of the parcel at the door</label><label class="pk" for="ph" style="margin-top:0">Take a photo</label><input id="ph" type="file" accept="image/*" capture="environment" hidden><img id="pv" hidden alt="Your photo">${+d.cod_amount?'<label for="cc">Cash collected</label><input id="cc" type="number" inputmode="decimal" step="0.01">':''}<p class="er" id="fe" hidden></p><button class="btn" data-a="fin" data-i="${d.id}">Complete delivery</button><button class="lnk" data-a="na" data-i="${d.id}">Recipient not available</button>`);
 const l=lab(d);show(hd+`<div style="text-align:center;padding:22px 0 6px"><span class="sp ${l[1]}">${l[0].toUpperCase()}</span></div>`+((d.flags||[]).length?`<h3>What we noticed</h3><ul>${d.flags.map(f=>`<li>${esc(f.t)}</li>`).join('')}</ul>`:'<p style="text-align:center;margin-top:12px">No issues found. Nice work.</p>'))}
async function photo(f){const bm=await createImageBitmap(f),k=Math.min(1,1024/Math.max(bm.width,bm.height)),c=document.createElement('canvas');c.width=bm.width*k;c.height=bm.height*k;c.getContext('2d').drawImage(bm,0,0,c.width,c.height);
 const blob=await new Promise(r=>c.toBlob(r,'image/jpeg',.7)),hash=await sha(await f.arrayBuffer());PH={blob,hash};$('#pv').src=URL.createObjectURL(blob);$('#pv').hidden=false;document.querySelector('label.pk').textContent='Retake photo'}
document.addEventListener('click',async e=>{const b=e.target.closest('[data-a]');if(!b){if(e.target==dlg)dlg.close();return}const a=b.dataset.a,i=b.dataset.i;try{switch(a){
 case'tab':tab=i;render(1);scrollTo(0,0);break;case'x':dlg.close();break;case'dt':PH=null;sheet(i);break;
 case'arr':{if(!navigator.onLine)return T("You're offline. Connect and try again.",1);show('<div class="rd"></div><p style="text-align:center">Checking your location…</p>');const r=await API.arrive(i,await loc());
  if(!r.ok){sheet(i);shake();T(r.message||`You're ${r.distance} m from the drop-off. Get within ${r.radius} m to check in.`,1);break}await API.refresh();render();sheet(i);T('Checked in');break}
 case'fin':{const d=R.t.find(x=>x.id==i),otp=$('#ot').value.trim(),cc=+d.cod_amount>0?parseFloat($('#cc').value):0,fe=$('#fe'),bad=m=>{fe.textContent=m;fe.hidden=false};fe.hidden=true;
  if(!/^\d{4}$/.test(otp))return bad('Enter the 4-digit code the recipient gives you.');if(!PH)return bad('Take a photo of the parcel at the door.');if(isNaN(cc))return bad('Enter the cash you collected.');if(!navigator.onLine)return bad("You're offline. Connect and try again.");
  b.disabled=true;b.textContent='Checking…';const r=await API.complete(i,{otp,pos:await loc(),cod:cc,p:PH});
  if(r.ok){PH=null;await API.refresh();render();sheet(i);break}if(r.locked){await API.refresh();render();sheet(i);T('Too many wrong codes. This delivery is locked.',1);break}
  b.disabled=false;b.textContent='Complete delivery';shake();bad(r.attempts_left!=null?`Wrong code. ${r.attempts_left} attempt${r.attempts_left>1?'s':''} left.`:r.message||'Something went wrong.');break}
 case'na':await API.gone(i);await API.refresh();render();sheet(i);break;
 case'out':await sb.auth.signOut();location.reload()}}catch(x){T(x.message||'Something went wrong',1);const d=R.t.find(y=>y.id==i);d&&dlg.open&&sheet(i)}});
document.addEventListener('change',e=>{if(e.target.id=='ph'&&e.target.files[0])photo(e.target.files[0]).catch(()=>T('Could not read that photo',1))});
addEventListener('online',()=>$('#off').hidden=true);addEventListener('offline',()=>$('#off').hidden=false);if(!navigator.onLine)$('#off').hidden=false;
if('serviceWorker' in navigator)addEventListener('load',()=>navigator.serviceWorker.register('sw.js').catch(()=>{}));
const ge=m=>{$('#ge').textContent=m;$('#ge').hidden=!m};
async function boot(){try{await API.load();$('#gate').hidden=true;$('#app').hidden=false;render(1)}catch(x){$('#gate').hidden=false;ge('Could not load data: '+(x.message||x))}}
async function enter(u){const {data:p}=await sb.from('profiles').select('role,status').eq('id',u.id).single(),no=async m=>{await sb.auth.signOut();$('#gate').hidden=false;ge(m)};
 if(!p||p.role!='rider')return no(p&&p.role=='merchant'?'Merchants sign in at /merchant/.':p&&p.role=='admin'?'Admins sign in at /admin/.':'This account cannot use the rider app.');
 if(p.status=='pending')return no('Your account is waiting for approval. You can sign in once an administrator approves it.');if(p.status!='active')return no('Your account is suspended. Contact your administrator.');await boot()}
$('#gf').onsubmit=async e=>{e.preventDefault();ge('');const b=e.target.querySelector('button');b.disabled=true;
 if(!sb)ge('Add your Supabase details to CONFIG first.');else{const {data,error}=await sb.auth.signInWithPassword({email:$('#e').value.trim(),password:$('#p').value});error?ge(/invalid/i.test(error.message)?'Email or password is incorrect.':error.message):await enter(data.user)}b.disabled=false};
if(!sb)boot();else sb.auth.getSession().then(({data})=>data.session?enter(data.session.user):($('#gate').hidden=false));
