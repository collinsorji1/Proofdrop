const CONFIG=window.PD_CONFIG||{url:'',key:''};
const $=s=>document.querySelector(s),$$=s=>[...document.querySelectorAll(s)],tok=decodeURIComponent(location.hash.slice(1));let sb=null,S=null,cur='',sel='',auto=0;
try{if(CONFIG.url&&CONFIG.key)sb=supabase.createClient(CONFIG.url,CONFIG.key)}catch(e){}
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),m2=n=>'$'+(+n||0).toFixed(2),calm=matchMedia('(prefers-reduced-motion:reduce)').matches,
tm=t=>new Date(t).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'}),vib=p=>navigator.vibrate&&!calm&&navigator.vibrate(p),
T=m=>{const t=$('#ts');t.textContent=m;t.className='on';clearTimeout(T.i);T.i=setTimeout(()=>t.className='',3200)},
stg=s=>!s?'nf':s.dispute?'rep':s.confirmed?'done':s.status=='delivered'?'del':s.status=='failed'?'fail':s.status=='arrived'?'door':s.status=='assigned'?'way':'wait',IDX={wait:0,way:1,door:2,del:3,done:3,rep:3,fail:2,nf:0};
const U={
wait:()=>`<div class="art bx"><div class="orb"><s></s><s></s><s></s></div><div class="box"></div></div><h2>Getting your parcel ready</h2><p>${esc(S.merchant)} is lining up a rider. This page updates by itself.</p>`,
way:()=>`<div class="art"><div class="route"><svg viewBox="0 0 320 100" aria-hidden="true"><path id="rp" class="rd" d="M12 78C70 78 66 24 130 24s84 48 134 28 46-24 48-24"/><g class="hm"><circle cx="308" cy="28" r="9"/><circle class="pls" cx="308" cy="28" r="9"/></g><g><circle r="10" fill="#16261d"/><circle r="4" fill="#0dbf6f"/><animateMotion dur="6s" repeatCount="indefinite"><mpath href="#rp"/></animateMotion></g></svg></div></div><h2>${esc(S.rider||'Your rider')} is on the way</h2><p>${esc(S.vehicle||'Heading')} to ${esc(S.address)}. Have your code ready.</p>${cash()}`,
door:()=>`<div class="art"><i class="ring"></i><i class="ring"></i><i class="ring"></i><div class="dr"></div></div><h2>Your rider is at the door</h2><p>Show them your code to receive the parcel.</p>${cash()}`,
del:()=>`<div class="art"><svg class="ck" viewBox="0 0 120 120" aria-hidden="true"><circle cx="60" cy="60" r="50"/><path d="M38 62l15 15 30-34"/></svg><div class="stamp">Delivered</div></div><h2>Delivered!</h2><p>Handed over${S.completed_at?' at '+tm(S.completed_at):''}.</p><div class="ask"><h3>Did it arrive?</h3><button class="btn" data-a="yes">Yes, I got it</button><button class="btn o" data-a="no" id="no">Something's wrong</button><div class="chips" id="chips"><div>${['Not received','Damaged','Wrong item'].map(r=>`<button class="pk" data-a="pick" data-r="${r}">${r}</button>`).join('')}<button class="btn" id="send" data-a="send" disabled>Send report</button></div></div></div>`,
done:()=>`<div class="art"><svg class="ck" viewBox="0 0 120 120" aria-hidden="true"><circle cx="60" cy="60" r="50"/><path d="M38 62l15 15 30-34"/></svg></div><h2>All done. Thank you!</h2><p>You confirmed this delivery. Enjoy your parcel.</p>`,
rep:()=>`<div class="art sad bx"><div class="box"></div></div><h2>Report sent</h2><p>${esc(S.merchant)} has been told: “${esc(S.dispute)}”. ${S.resolved?'They marked it as resolved.':"They'll look into it."}</p>`,
fail:()=>`<div class="art sad bx"><div class="box"></div></div><h2>We couldn't deliver this time</h2><p>${esc(S.merchant)} will be in touch about trying again.</p>`,
nf:()=>`<div class="art sad bx"><div class="box"></div></div><h2>We can't find that delivery</h2><p>Check the link, or ask the sender for a new one.</p>`},
cash=()=>S&&+S.cod?`<span class="cash">Pay on delivery: ${m2(S.cod)}</span>`:'',
code=()=>`<button class="code" data-a="flip" aria-pressed="false" aria-label="Show my handoff code"><span class="in"><span class="f fr">Tap to show your code</span><span class="f bk">${[...String(S.otp)].map(d=>`<b>${esc(d)}</b>`).join('')}</span></span></button><p class="hint">Hidden until you tap, so nobody can peek.</p>`;
function burst(){if(calm)return;const c=$('#cv'),x=c.getContext('2d'),cs=['#0dbf6f','#ffd968','#d9d0ff','#ffc9bd','#16261d'];c.width=innerWidth;c.height=innerHeight;
 const P=Array.from({length:150},()=>({x:innerWidth/2,y:innerHeight*.38,vx:(Math.random()-.5)*18,vy:-Math.random()*17-4,r:Math.random()*8+4,c:cs[Math.random()*5|0],a:Math.random()*6,va:(Math.random()-.5)*.4,l:1}));
 (function f(){x.clearRect(0,0,c.width,c.height);let n=0;P.forEach(p=>{p.vy+=.36;p.x+=p.vx;p.y+=p.vy;p.vx*=.99;p.a+=p.va;p.l-=.006;if(p.l>0&&p.y<c.height+20){n++;x.save();x.globalAlpha=p.l;x.translate(p.x,p.y);x.rotate(p.a);x.fillStyle=p.c;x.fillRect(-p.r/2,-p.r/4,p.r,p.r/2);x.restore()}});n?requestAnimationFrame(f):x.clearRect(0,0,c.width,c.height)})()}
function tl(s){$('#tl').hidden=s=='nf';$('#lf').style.width=IDX[s]/3*100+'%';$$('.n').forEach((n,i)=>{n.classList.toggle('on',i<=IDX[s]&&s!='fail'||i<=2&&s=='fail'&&i<IDX[s]);n.classList.toggle('cur',i==IDX[s]&&!['done','rep','fail','nf'].includes(s))})}
function paint(){const s=stg(S);$('#mer').textContent=S?S.merchant:'Unknown sender';$('#adr').textContent=S?S.address:'';if(s==cur)return;const was=cur;cur=s;const e=$('#stg');
 e.innerHTML=U[s]()+(S&&S.otp&&['wait','way','door'].includes(s)?code():'');e.classList.remove('sw');void e.offsetWidth;e.classList.add('sw');tl(s);
 if(was&&s=='door')vib([220,90,220]);if(s=='del'){vib(300);burst()}if(s=='done')burst()}
let API;
if(sb)API={async view(){const {data,error}=await sb.rpc('recipient_view',{p_token:tok});if(error)throw error;return data},async reply(a,r){const {data,error}=await sb.rpc('recipient_respond',{p_token:tok,p_action:a,p_reason:r||null});if(error)throw error;if(!data.ok)throw new Error(data.message||'Could not send that')}};
else{S={merchant:'Northline Goods',address:'14 Palm Ave',status:'created',otp:'4821',cod:185,rider:'Bola',vehicle:'Motorbike',completed_at:null,confirmed:false,dispute:null,resolved:false};
 API={async view(){return S},async reply(a,r){if(a=='confirm')S.confirmed=true;else S.dispute=r}}}
function jump(k){const m={wait:['created'],way:['assigned'],door:['arrived'],del:['delivered'],fail:['failed'],done:['delivered',1],rep:['delivered',0,'Not received']}[k];Object.assign(S,{status:m[0],confirmed:!!m[1],dispute:m[2]||null,completed_at:m[0]=='delivered'||m[0]=='failed'?new Date():null});paint()}
async function sync(){try{const d=await API.view();$('#net').hidden=true;S=d;paint()}catch(x){$('#net').hidden=false}}
document.addEventListener('click',async e=>{const b=e.target.closest('[data-a]');if(!b)return;const a=b.dataset.a;
 if(a=='flip'){b.classList.toggle('on');b.setAttribute('aria-pressed',b.classList.contains('on'))}
 if(a=='pj'){clearTimeout(auto);jump(b.dataset.k)}
 if(a=='no'){$('#chips').classList.add('o');b.hidden=true}
 if(a=='pick'){sel=b.dataset.r;$$('.pk').forEach(x=>x.classList.toggle('on',x==b));$('#send').disabled=false}
 if(a=='yes'||a=='send'){b.disabled=true;try{await API.reply(a=='yes'?'confirm':'report',sel);await sync()}catch(x){b.disabled=false;T(x.message||'Something went wrong')}}});
if(matchMedia('(pointer:fine)').matches&&!calm){const c=$('#card');addEventListener('pointermove',e=>{const x=e.clientX/innerWidth-.5,y=e.clientY/innerHeight-.5;c.style.setProperty('--ry',x*7+'deg');c.style.setProperty('--rx',-y*7+'deg')})}
for(let i=0;i<18;i++){const b=document.createElement('b');b.style.cssText=`left:${Math.random()*100}%;top:${Math.random()*100}%;animation-delay:${Math.random()*3}s;animation-duration:${2.4+Math.random()*2.5}s`;$('#bg').appendChild(b)}
if(!tok&&sb){S=null;paint()}
else{sync();if(sb)setInterval(()=>{if(!document.hidden&&!['done','fail','nf'].includes(cur))sync()},6000);
 else{$('#pb').hidden=false;const seq=['way','door','del'];let i=0;(function nx(){if(i<seq.length)auto=setTimeout(()=>{jump(seq[i++]);nx()},5200)})()}}
