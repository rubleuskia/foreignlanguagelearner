import {activeTasks,createAttempt,examResumePosition,formatDuration,gradeSection,isAnswered,points,secondsElapsed,trainingAudioWindow} from './logic.mjs';
const $=id=>document.getElementById(id);
const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const ids=['listening','reading','grammar'];
const descriptions={listening:'Posłuchaj nagrania i rozwiąż zadania zgodnie z oryginalnym arkuszem.',reading:'Przeczytaj teksty i uzupełnij odpowiedzi w arkuszu.',grammar:'Uzupełnij zdania i wybierz poprawne formy. Zachowaj polskie znaki.'};
const icons={listening:'♫',reading:'▤',grammar:'Aa'};
let exam,audioData,attempt,key,fingerprint,current,playingTask=null,playingEnd=null,toastTimer,lastAudioSave=0;
const sections=()=>exam.sections.filter(s=>ids.includes(s.id));
const section=()=>sections().find(s=>s.id===current);
const tasks=()=>activeTasks(section(),attempt.selected_tasks[current]);
const items=()=>tasks().flatMap(t=>t.items??[]);
const state=(id=current)=>attempt.sections[id]??={elapsed_seconds:0,running_since:null,submitted_at:null};
const isExam=()=>attempt.mode==='exam';
const submitted=()=>Boolean(state().submitted_at);
const layout=t=>t.presentation?.layout??(t.interaction_type==='true_false'?'true_false_table':'question_list');
const option=(t,id)=>(t.options??[]).find(o=>o.id===id);
const optionText=(t,id)=>{const o=option(t,id);return o?`${o.label?`${o.label}) `:''}${o.text??''}`:String(id);};

function toast(text){$('toast').textContent=text;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>{$('toast').hidden=true;},3500);}
async function confirmAction(title,description,confirmLabel){
  const dialog=$('action-dialog');
  if(dialog.open)return false;
  $('action-dialog-title').textContent=title;
  $('action-dialog-description').textContent=description;
  $('action-dialog-confirm').textContent=confirmLabel;
  dialog.returnValue='cancel';
  return new Promise(resolve=>{
    dialog.addEventListener('close',()=>resolve(dialog.returnValue==='confirm'),{once:true});
    dialog.showModal();
  });
}
function persist(){
  attempt.updated_at=new Date().toISOString();attempt.current_section_id=current;
  try{localStorage.setItem(key,JSON.stringify(attempt));$('save-status').textContent='Odpowiedzi zapisane na tym urządzeniu';}
  catch{$('save-status').textContent='Zapis niedostępny. Pobierz odpowiedzi przed zamknięciem.';}
}
function source(id){return (Array.isArray(exam.sources)?exam.sources:Object.values(exam.sources??{})).find(s=>s.id===id||s.source_id===id);}
function sourceUrl(s){const p=String(s?.path??'').replace(/^\/+/, '');return !p||p.split('/').includes('..')||/^(?:https?:|javascript:|data:)/i.test(p)?null:`/${p.split('/').map(encodeURIComponent).join('/')}`;}
function sourceLink(refs,label='Oryginał ↗',allowKeys=false){const r=(refs??[]).find(r=>allowKeys||r.source_id!=='keys');const u=r?sourceUrl(source(r.source_id)):null;return u?`<a class="source-link" href="${esc(u)}${r.page?`#page=${Number(r.page)}`:''}" target="_blank" rel="noopener">${esc(label)}${r.page?` · s. ${Number(r.page)}`:''}</a>`:'';}

function feedback(item,task,compact=false){
  if(!submitted())return '';
  const r=gradeSection(section(),attempt.answers,attempt.selected_tasks[current]).responses[item.id];if(!r)return '';
  const labels={correct:'Dobrze',partial:'Częściowo poprawnie',incorrect:'Niepoprawna odpowiedź',invalid:'Nieprawidłowy zapis odpowiedzi',unanswered:'Brak odpowiedzi',pending:'Oczekuje na ocenę AI'};
  let answer='';
  if(r.status==='pending'){const ref=item.grading?.reference_answer;if(ref)answer=Array.isArray(ref)?ref.map(id=>optionText(task,id)).join(', '):typeof ref==='object'?JSON.stringify(ref):ref;}
  else{const a=item.grading?.accepted_answers??[];answer=item.grading.mode==='token_membership'?a.join(', '):a.map(v=>Array.isArray(v)?v.map(id=>optionText(task,id)).join(', '):item.response_type.includes('choice')?optionText(task,v):String(v)).join(' / ');}
  const score=r.score_units===null?'':` · ${points(r.score_units)}${r.max_score_units!==null?` / ${points(r.max_score_units)}`:''} pkt`;
  return `<div class="feedback ${esc(r.status)} ${compact?'compact-feedback':''}"><strong>${labels[r.status]??r.status}${score}</strong>${r.reason==='too_many_tokens'?'<div>Wpisano za dużo różnych odpowiedzi.</div>':''}${answer?`<div>${r.status==='pending'?'Przykładowa odpowiedź':'Odpowiedź w kluczu'}: ${esc(answer)}</div>`:''}${r.status==='pending'?'<div>Ocena AI jest w tym prototypie zastąpiona oczekiwaniem na sprawdzenie.</div>':''}${sourceLink(item.grading?.source_refs,'Klucz ↗',true)}</div>`;
}
function field(item,task,kind){
  const value=attempt.answers[item.id]??'',disabled=submitted()?'disabled':'',label=`Odpowiedź ${item.label}, zadanie ${task.label}`;
  if(kind==='inline_choices')return `<span class="inline-field-wrap word-choice-wrap" id="item-${esc(item.id)}"><sup>${esc(item.label)}</sup><span class="inline-choice-group" role="radiogroup" aria-label="${esc(label)}">(${(item.option_ids??[]).map(id=>`<label class="inline-word-option"><input type="radio" name="${esc(item.id)}" data-item="${esc(item.id)}" value="${esc(id)}" ${value===id?'checked':''} ${disabled}><span>${esc(option(task,id)?.text??id)}</span></label>`).join(', ')})</span></span>`;
  const short=['letter','number'].includes(task.presentation?.input_format??task.presentation?.input_kind);
  return `<span class="inline-field-wrap" id="item-${esc(item.id)}"><sup>${esc(item.label)}</sup><input class="inline-gap ${short?'short-gap':''}" data-item="${esc(item.id)}" type="text" value="${esc(value)}" placeholder="…" aria-label="${esc(label)}" autocomplete="off" spellcheck="false" ${short?'maxlength="2"':''} ${disabled}></span>`;
}
function content(text,task,underline){
  let html=esc(text).replace(/\{\{([^}]+)\}\}/gu,(_,id)=>{const item=(task.items??[]).find(i=>i.id===id);return item?field(item,task,layout(task)):'';}).replace(/\[PRZYKŁAD:\s*([A-Za-z0-9])\]/gu,(_,answer)=>`<span class="worked-inline-example"><span class="worked-example-value">${answer}</span><sup>przykład</sup></span>`).replace(/\[PRZYKŁAD:\s*([^\]]+)\]/gu,(_,text)=>`<span class="inline-example">Przykład: ${text}</span>`);
  if(underline)html=html.replace(esc(underline),`<u class="source-underline">${esc(underline)}</u>`);return html;
}
function block(b,t){
  if(b.type==='image'){
    const path=b.path??b.asset_path;
    if(!path)return `<p>${sourceLink(b.source_refs,'Ilustracja w oryginale ↗')}</p>`;
    const src=`/${String(path).split('/').map(encodeURIComponent).join('/')}`,label=esc(b.alt??b.text??'Ilustracja z arkusza');
    const r=b.image_region;
    const size=b.image_page_size;
    if(Array.isArray(r)&&r.length===4&&r.every(v=>Number.isFinite(v)&&v>=0&&v<=1)&&r[2]>0&&r[3]>0&&r[0]+r[2]<=1&&r[1]+r[3]<=1&&Array.isArray(size)&&size.length===2&&size.every(v=>Number.isFinite(v)&&v>0)){
      const view=[r[0]*size[0],r[1]*size[1],r[2]*size[0],r[3]*size[1]];
      return `<figure><svg class="source-image" role="img" aria-label="${label}" viewBox="${view.join(' ')}"><image href="${src}" width="${size[0]}" height="${size[1]}" preserveAspectRatio="none"/></svg></figure>`;
    }
    return `<figure><img class="source-image" src="${src}" alt="${label}"><figcaption>${sourceLink(b.source_refs)}</figcaption></figure>`;
  }
  const tag=b.type==='heading'?'h3':'div';
  return `<${tag} class="reading-block ${esc(b.type??'')} ${b.role==='attribution'?'attribution':''}">${content(b.text,t,b.underlined_text)}${b.type==='example'&&b.answer!==undefined?`<div class="example-answer">Odpowiedź: <strong>${esc(b.answer)}</strong></div>`:''}</${tag}>`;
}
function bank(t,table=false){
  if(!(t.options??[]).length)return '';
  const examples=new Set(t.presentation?.example_option_ids??[]);
  return table?`<table class="source-table option-table"><caption>Fragmenty do wyboru</caption><tbody>${t.options.map(o=>`<tr${examples.has(o.id)?' class="example-row"':''}><th scope="row">${esc(t.presentation?.display_codes?.[o.id]??o.label)}${examples.has(o.id)?'<span class="bank-example-tag">Przykład</span>':''}</th><td>${esc(o.text)}</td></tr>`).join('')}</tbody></table>`:`<div class="word-bank">${t.options.map(o=>`<span>${esc(o.text)}</span>`).join('')}</div>`;
}
function trueFalseTable(t){
  const opts=t.options??[],example=(t.blocks??[]).find(b=>b.type==='example');
  const e=example?`<tr class="example-row"><th scope="row"><span class="table-example-label">PRZYKŁAD</span>${esc(example.text)}</th>${opts.map(o=>`<td>${String(example.answer)===String(o.label)||String(example.answer)===String(o.text)?'<span aria-label="Zaznaczono">×</span>':''}</td>`).join('')}</tr>`:'';
  return `<div class="table-scroll"><table class="source-table true-false-table"><thead><tr><th scope="col">Zdanie</th>${opts.map(o=>`<th scope="col">${esc(o.label)}</th>`).join('')}</tr></thead><tbody>${e}${t.items.map(i=>`<tr id="item-${esc(i.id)}"><th scope="row"><span class="table-item-label">${esc(i.label)}.</span>${esc(i.prompt)}${feedback(i,t,true)}</th>${opts.map(o=>`<td><label class="table-radio"><input type="radio" name="${esc(i.id)}" data-item="${esc(i.id)}" value="${esc(o.id)}" ${attempt.answers[i.id]===o.id?'checked':''} ${submitted()?'disabled':''} aria-label="${esc(`${i.label}. ${i.prompt} — ${o.label}`)}"><span aria-hidden="true"></span></label></td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
}
function tokenTable(t){
  const e=(t.blocks??[]).find(b=>b.type==='example');
  return `${(t.blocks??[]).filter(b=>b.type!=='example').map(b=>block(b,t)).join('')}${bank(t,true)}<div class="table-scroll"><table class="source-table token-table"><thead><tr><th scope="col">${esc(t.presentation?.prompt_header??'Opinia')}</th><th scope="col">${esc(t.presentation?.answer_header??'O tym mówi')}</th></tr></thead><tbody>${e?`<tr class="example-row"><th scope="row"><span class="table-example-label">PRZYKŁAD</span>${esc(e.text)}</th><td>${esc(e.answer)}</td></tr>`:''}${t.items.map(i=>`<tr id="item-${esc(i.id)}"><th scope="row"><span class="table-item-label">${esc(i.label)}</span>${esc(i.prompt)}${feedback(i,t,true)}</th><td><input class="table-input token-input" type="text" data-item="${esc(i.id)}" value="${esc(attempt.answers[i.id]??'')}" aria-label="${esc(`Odpowiedź ${i.label}`)}" autocomplete="off" placeholder="${(i.grading?.max_tokens??1)>1?'odpowiedzi':'odpowiedź'}" ${submitted()?'disabled':''}><span class="field-hint">${(i.grading?.max_tokens??1)>1?`${i.grading.max_tokens} odpowiedzi; dowolny separator`:'1 odpowiedź'}</span></td></tr>`).join('')}</tbody></table></div>`;
}
function matchingTable(t){
  const e=(t.blocks??[]).find(b=>b.type==='example'),rows=t.presentation?.rows??[];
  const table=`<div class="table-scroll"><table class="source-table matching-source-table"><thead><tr><th colspan="2" scope="colgroup">I</th><th colspan="2" scope="colgroup">II</th></tr></thead><tbody>${rows.map(r=>`<tr><th scope="row" class="matching-index">${esc(r.label??r.left_label??'')}</th><td>${esc(r.left??r.left_text??'')}</td><th scope="row" class="matching-index">${esc(r.right_label??'')}</th><td>${esc(r.right??r.right_text??'')}</td></tr>`).join('')}</tbody></table></div>`;
  return `${(t.blocks??[]).filter(b=>b.type==='heading').map(b=>block(b,t)).join('')}${table}<div class="table-scroll"><table class="source-table answer-table"><caption>${t.presentation?.input_format==='letter'?'Wpisz litery odpowiedzi':'Wpisz numery odpowiedzi'}</caption><thead><tr><th scope="col">PRZYKŁAD</th>${t.items.map(i=>`<th scope="col">${esc(i.label)}.</th>`).join('')}</tr></thead><tbody><tr><td class="example-row">${esc(t.presentation?.example_answer??e?.answer??'')}</td>${t.items.map(i=>`<td id="item-${esc(i.id)}"><input class="table-input short-answer" type="text" data-item="${esc(i.id)}" value="${esc(attempt.answers[i.id]??'')}" aria-label="${esc(`Odpowiedź ${i.label}`)}" ${t.presentation?.input_format==='letter'?'':'inputmode="numeric"'} autocomplete="off" maxlength="2" ${submitted()?'disabled':''}></td>`).join('')}</tr></tbody></table></div>${submitted()?t.items.map(i=>`<div class="compact-review"><strong>${esc(i.label)}.</strong>${feedback(i,t,true)}</div>`).join(''):''}`;
}
function sourceForm(t){
  return (t.presentation?.rows??[]).map(row=>{
    const item=t.items.find(i=>i.id===row.item_id);if(!item)return '';
    const question=row.question_template?content(row.question_template,t):field(item,t,'inline_text');
    return `<div class="source-text-item" id="source-${esc(item.id)}"><span class="table-item-label">${esc(row.label??item.label)}.</span><div class="source-text-prompt"><div>${content(row.statement,t,row.underlined_text)}</div>${row.required_word?`<div class="required-word">(${esc(row.required_word)})</div>`:''}<div class="source-question">${question}</div>${row.answer_line?`<div>${esc(row.answer_line)}</div>`:''}</div>${feedback(item,t)}</div>`;
  }).join('');
}
function question(i,t){
  const value=attempt.answers[i.id];let input='';
  if(i.response_type==='single_choice')input=`<div class="choice-grid">${i.option_ids.map(id=>{const o=option(t,id);return `<label class="choice"><input type="radio" name="${esc(i.id)}" data-item="${esc(i.id)}" value="${esc(id)}" ${value===id?'checked':''} ${submitted()?'disabled':''}><span class="choice-label">${esc(o.label)}</span><span class="choice-text">${esc(o.text)}</span></label>`;}).join('')}</div>`;
  else input=`<input class="item-input" type="text" data-item="${esc(i.id)}" value="${esc(value??'')}" aria-label="${esc(`Odpowiedź ${i.label}`)}" autocomplete="off" ${submitted()?'disabled':''}>`;
  return `<div class="item" id="item-${esc(i.id)}">${(t.blocks??[]).filter(b=>b.item_id===i.id).map(b=>block(b,t)).join('')}${i.context?`<div class="item-context">${content(i.context,t,i.underlined_text)}</div>`:''}<div class="item-heading"><span class="item-label">${esc(i.label)}.</span><h3 class="item-prompt">${content(i.prompt,t,i.underlined_text)}</h3><span class="item-weight">${points(i.max_score_units)} pkt</span></div>${input}${feedback(i,t)}</div>`;
}

function audioTask(t){
  if(!t)return null;const hash=audioData?.source?.sha256??audioData?.source_sha256;
  if(hash&&source('audio')?.sha256&&hash!==source('audio').sha256)return null;
  return (audioData?.tasks??[]).find(a=>String(a.task_label)===String(t.label)||a.task_id===t.id);
}
function audioWindow(t){return trainingAudioWindow(audioTask(t)?.occurrences);}
function taskAudio(t){
  if(current!=='listening'||isExam())return '';const w=audioWindow(t);if(!w)return '<p class="alignment-note">Brak sprawdzonych znaczników tego zadania. Dostępny jest oryginał.</p>';
  const p=Math.max(w.start_ms,Math.min(w.end_ms,attempt.media.training_positions[t.id]??w.start_ms));
  return `<div class="task-player" data-player="${esc(t.id)}"><div class="task-player-main"><button class="task-play-button" data-task-play="${esc(t.id)}" type="button" aria-label="Odtwórz zadanie ${esc(t.label)}">▷</button><input class="task-seek" type="range" data-task-seek="${esc(t.id)}" min="0" max="${w.end_ms-w.start_ms}" step="100" value="${p-w.start_ms}" aria-label="Pozycja nagrania zadania ${esc(t.label)}"><span class="audio-time" data-task-clock="${esc(t.id)}">${formatDuration((p-w.start_ms)/1000)} / ${formatDuration((w.end_ms-w.start_ms)/1000)}</span></div><div class="task-player-caption"><span>Całe zadanie${w.occurrences.length>1?' z powtórzeniem':''}</span><span>${w.occurrences.map((o,n)=>`<button class="text-button occurrence-link" data-task-occurrence="${esc(t.id)}" data-occurrence="${n}" type="button">${n?'Powtórzenie':'Pierwszy odsłuch'}</button>`).join('')}</span></div></div>`;
}
function renderTask(t){
  const kind=layout(t),blocks=t.blocks??[];let body='';
  if(kind==='true_false_table')body=blocks.filter(b=>b.type!=='example').map(b=>block(b,t)).join('')+trueFalseTable(t);
  else if(kind==='token_table')body=tokenTable(t);
  else if(kind==='matching_table')body=matchingTable(t);
  else if(kind==='source_form')body=blocks.map(b=>block(b,t)).join('')+sourceForm(t);
  else if(kind.startsWith('inline_')){
    const bankHtml=kind==='inline_bank'?bank(t,t.presentation?.option_bank==='table'):'';
    const textHtml=blocks.filter(b=>!(t.presentation?.suppress_example_blocks&&b.type==='example')).map(b=>block(b,t)).join('');
    body=t.presentation?.bank_position==='after_text'?textHtml+bankHtml:bankHtml+textHtml;
    const inText=new Set(blocks.flatMap(b=>[...String(b.text??'').matchAll(/\{\{([^}]+)\}\}/gu)].map(m=>m[1])));
    body+=t.items.filter(i=>!inText.has(i.id)).map(i=>question(i,t)).join('');
    if(submitted())body+=`<div class="inline-review">${t.items.filter(i=>inText.has(i.id)).map(i=>`<div class="compact-review"><strong>${esc(i.label)}.</strong>${feedback(i,t,true)}</div>`).join('')}</div>`;
  }else body=blocks.filter(b=>!b.item_id).map(b=>block(b,t)).join('')+t.items.map(i=>question(i,t)).join('');
  return `<article class="task-card" id="task-${esc(t.id)}"><header class="task-header"><div class="task-title-row"><span class="task-number">${esc(t.label)}</span><div><h2>${esc(t.title||`Zadanie ${t.label}`)}</h2><span class="task-points">Maksymalnie ${points(t.max_score_units)} pkt</span></div></div>${sourceLink(t.source_refs)}</header><div class="task-body"><p class="instruction">${esc(t.instruction)}</p>${taskAudio(t)}${body}</div></article>`;
}

function renderNav(){
  $('section-nav').innerHTML=sections().map(s=>{const all=s.tasks.flatMap(t=>t.items??[]),count=all.filter(i=>isAnswered(attempt.answers[i.id])).length,status=state(s.id).submitted_at?'Zakończono':count?`${count} / ${all.length} odpowiedzi`:'Gotowe do rozpoczęcia';return `<button class="nav-section ${s.id===current?'active':''}" type="button" data-section="${esc(s.id)}" ${s.id===current?'aria-current="page"':''} ${!attempt.mode?'disabled':''}><span class="nav-icon" aria-hidden="true">${icons[s.id]}</span><span class="nav-label">${esc(s.title)}<span class="nav-status">${status}</span></span></button>`;}).join('');
}
function progress(){const all=items(),count=all.filter(i=>isAnswered(attempt.answers[i.id])).length,p=all.length?Math.round(count/all.length*100):0;$('progress-label').textContent=`${count} z ${all.length} odpowiedzi`;$('progress-fill').value=p;$('progress-percent').textContent=`${p}%`;}
function updateTimer(){
  if(!exam||!attempt.mode)return;const s=section(),timer=state(),elapsed=secondsElapsed(timer),limit=s.time_limit_seconds;
  $('timer-card').hidden=!limit;$('timer').textContent=formatDuration(limit?Math.max(0,limit-elapsed):elapsed);$('timer-toggle').hidden=isExam();$('timer-toggle').textContent=timer.running_since?'Wstrzymaj':elapsed?'Kontynuuj':'Rozpocznij';$('timer-toggle').disabled=Boolean(timer.submitted_at);
  $('timer-hint').textContent=timer.submitted_at?'Część zakończona.':limit&&elapsed>=limit?'Czas tej części minął.':isExam()?'Czas biegnie po otwarciu części.':'Możesz zatrzymać czas.';
}
function pauseTimer(id){const timer=state(id);if(timer.running_since){timer.elapsed_seconds=secondsElapsed(timer);timer.running_since=null;}}
function renderResult(){
  $('result').hidden=!submitted();if(!submitted())return;const r=gradeSection(section(),attempt.answers,attempt.selected_tasks[current]);
  const pending=r.pending_count>0;
  const score=pending?(r.auto_max_score_units>0?`${points(r.objective_score_units)} <span>/ ${points(r.auto_max_score_units)}</span><small class="result-score-caption">pkt ocenione automatycznie</small>`:'—<small class="result-score-caption">oczekuje na ocenę AI</small>'):`${points(r.objective_score_units)} <span>/ ${points(r.max_score_units)} pkt</span>`;
  $('result').innerHTML=`<div><div class="eyebrow">${pending?'WYNIK CZĘŚCIOWY':'CZĘŚĆ ZAKOŃCZONA'}</div><h2>Zobacz, jak Ci poszło</h2><p>${r.answered} z ${r.total} odpowiedzi udzielonych.${pending?` Do ${points(r.pending_score_units)} pkt oczekuje na ocenę AI.`:''}</p>${pending?'<p><strong>Wynik całej części: oczekuje na ocenę AI.</strong></p>':''}</div><div class="result-score">${score}</div>`;
}
function audioControls(){
  if(!attempt?.mode)return;const audio=$('exam-audio');
  if(isExam()){
    const media=attempt.media.exam_audio,duration=Number.isFinite(audio.duration)?audio.duration:(audioData?.source?.duration_ms??0)/1000;
    $('exam-audio-progress').max=duration||1;$('exam-audio-progress').value=media.finished?duration:audio.currentTime;$('exam-audio-time').textContent=`${formatDuration(audio.currentTime)} / ${formatDuration(duration)}`;
    $('exam-audio-start').textContent=media.finished?'Nagranie zakończone':media.started?'Kontynuuj po przerwie':'Rozpocznij nagranie';$('exam-audio-start').hidden=media.started&&!audio.paused&&!media.finished;$('exam-audio-start').disabled=media.finished;
    $('audio-note').textContent=media.finished?'Oryginalne nagranie zostało odtworzone.':media.started&&audio.paused?'Przeglądarka zatrzymała dźwięk. Kontynuuj od zapisanej pozycji.':'Nagranie bez pauzy i przewijania. Oryginał zawiera już powtórzenia.';
  }else{
    document.querySelectorAll('[data-task-play]').forEach(b=>{const active=b.dataset.taskPlay===playingTask&&!audio.paused;b.textContent=active?'Ⅱ':'▷';b.setAttribute('aria-label',`${active?'Wstrzymaj':'Odtwórz'} zadanie ${b.dataset.taskPlay.replace('listening-','')}`);});
    for(const t of exam.sections.find(s=>s.id==='listening')?.tasks??[]){const w=audioWindow(t);if(!w)continue;const p=attempt.media.training_positions[t.id]??w.start_ms,range=[...document.querySelectorAll('[data-task-seek]')].find(e=>e.dataset.taskSeek===t.id),clock=[...document.querySelectorAll('[data-task-clock]')].find(e=>e.dataset.taskClock===t.id);if(range)range.value=Math.max(0,p-w.start_ms);if(clock)clock.textContent=`${formatDuration(Math.max(0,p-w.start_ms)/1000)} / ${formatDuration((w.end_ms-w.start_ms)/1000)}`;}
  }
}
function renderSetup(){$('exam-content').hidden=true;$('attempt-setup').hidden=false;$('mode-badge').innerHTML='<span class="status-dot"></span>Wybierz tryb';$('setup-exam-title').textContent=`Egzamin ${exam.level} · ${exam.session?.label??exam.title}`;$('export-attempt').disabled=true;renderNav();}
function renderSection(){
  if(!attempt.mode){renderSetup();return;}const s=section();renderNav();$('attempt-setup').hidden=true;$('exam-content').hidden=false;
  $('mode-badge').innerHTML=`<span class="status-dot"></span>${isExam()?'Symulacja egzaminu':'Tryb treningowy'}`;$('breadcrumbs').innerHTML=`Egzamin certyfikatowy <span> / ${esc(exam.level)} / ${esc(exam.session?.label??'')}</span>`;
  $('section-kicker').textContent=`CZĘŚĆ ${sections().indexOf(s)+1} · POZIOM ${exam.level}`;$('section-title').textContent=s.title;$('section-description').textContent=descriptions[s.id];
  $('section-meta').innerHTML=[`${s.tasks.length} zadań`,s.time_limit_seconds?`${Math.round(s.time_limit_seconds/60)} minut`:null,`${points(s.max_score_units)} punktów`].filter(Boolean).map(v=>`<span><i class="meta-dot" aria-hidden="true"></i>${esc(v)}</span>`).join('');
  $('audio-panel').hidden=!isExam()||s.id!=='listening';$('task-tabs').innerHTML=tasks().map(t=>`<a class="task-tab" href="#task-${esc(t.id)}">Zadanie ${esc(t.label)}</a>`).join('');$('selection').hidden=true;$('tasks').innerHTML=tasks().map(renderTask).join('');
  $('submit-section').textContent=submitted()?(isExam()?'Część zakończona':'Wróć do odpowiedzi'):'Zakończ i sprawdź →';$('submit-section').disabled=submitted()&&isExam();$('footer-note').textContent=submitted()?'Odpowiedzi zostały zapisane.':isExam()?'Po zakończeniu tej części nie można zmienić odpowiedzi.':'Sprawdź odpowiedzi, gdy skończysz. Do tego czasu możesz je zmieniać.';
  $('provenance-note').innerHTML=`Materiały: Państwowa Komisja ds. Poświadczania Znajomości Języka Polskiego jako Obcego. ${sourceLink(s.source_refs,'Arkusz źródłowy ↗')}<br>${isExam()?'Lokalna symulacja. Po zamknięciu lub odświeżeniu strony dźwięk może wymagać ręcznego wznowienia od zapisanej pozycji.':'Tryb treningowy pozwala zatrzymać czas, przewijać nagranie i wrócić do odpowiedzi.'}${submitted()?` ${sourceLink([{source_id:'keys'}],'Transkrypcje i oficjalne klucze ↗',true)}`:''}`;
  progress();updateTimer();renderResult();audioControls();
}
function stopTraining(){if(isExam())return;$('exam-audio').pause();playingEnd=null;audioControls();}
function switchSection(id){if(id===current||!attempt.mode)return;if(!isExam())pauseTimer(current);stopTraining();current=id;if(isExam()&&!state().submitted_at&&!state().running_since)state().running_since=Date.now();persist();renderSection();window.scrollTo({top:0,behavior:'instant'});$('content').focus({preventScroll:true});}
function capture(event){const input=event.target,id=input.dataset.item;if(!id||submitted())return;attempt.answers[id]=input.value;persist();progress();renderNav();}
async function playTraining(t,position){
  const w=audioWindow(t);if(!w)return;const a=$('exam-audio');if(playingTask===t.id&&!a.paused&&position===undefined){a.pause();audioControls();return;}playingTask=t.id;playingEnd=w.end_ms;
  const saved=position??attempt.media.training_positions[t.id]??w.start_ms;a.currentTime=saved>=w.end_ms?w.start_ms/1000:Math.max(w.start_ms,saved)/1000;attempt.media.training_positions[t.id]=a.currentTime*1000;
  try{await a.play();audioControls();}catch{toast('Kliknij odtwarzanie ponownie, aby uruchomić dźwięk.');}
}
async function startExamAudio(){
  const a=$('exam-audio'),m=attempt.media.exam_audio;if(!isExam()||m.finished||m.started&&!a.paused)return;
  const position=examResumePosition(m,Number.isFinite(a.duration)?a.duration*1000:undefined);
  if(position===null){m.finished=true;persist();audioControls();return;}
  a.currentTime=position/1000;
  try{await a.play();m.started=true;persist();audioControls();}catch{toast('Przeglądarka wymaga kliknięcia, aby uruchomić dźwięk.');}
}
async function submitSection(force=false){
  if(submitted()){if(isExam())return;state().submitted_at=null;persist();renderSection();return;}
  const n=items().filter(i=>!isAnswered(attempt.answers[i.id])).length;
  if(!force&&n){const originalSection=current;const approved=await confirmAction('Zakończyć tę część?',`Pozostało ${n} odpowiedzi bez uzupełnienia. Możesz wrócić do arkusza lub zakończyć tę część.`, 'Zakończ część');if(!approved||current!==originalSection||submitted())return;}
  pauseTimer(current);stopTraining();state().submitted_at=new Date().toISOString();persist();renderSection();$('result').scrollIntoView({behavior:'smooth',block:'start'});
}
function exportAttempt(){
  const r=JSON.parse(JSON.stringify(attempt));r.revision=exam.revision??1;r.responses=r.answers;delete r.answers;delete r.exam_revision;r.exported_at=new Date().toISOString();
  for(const s of sections()){const timer=state(s.id);r.sections[s.id]={...timer,elapsed_seconds:secondsElapsed(timer),running_since:null};if(timer.submitted_at)r.sections[s.id].result=gradeSection(s,attempt.answers,attempt.selected_tasks[s.id]);}
  r.source_refs=(Array.isArray(exam.sources)?exam.sources:Object.values(exam.sources)).map(s=>({source_id:s.id??s.source_id,sha256:s.sha256,url:s.url}));const url=URL.createObjectURL(new Blob([JSON.stringify(r,null,2)],{type:'application/json'})),a=document.createElement('a');a.href=url;a.download=`${exam.id}-odpowiedzi.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('Plik z odpowiedziami został przygotowany.');
}
function events(){
  $('start-attempt').addEventListener('click',()=>{if(attempt.mode)return;attempt.mode=document.querySelector('[name="attempt-mode"]:checked').value;attempt.started_at=new Date().toISOString();if(isExam())state().running_since=Date.now();$('export-attempt').disabled=false;persist();renderSection();});
  $('section-nav').addEventListener('click',e=>{const b=e.target.closest('[data-section]');if(b)switchSection(b.dataset.section);});
  $('timer-toggle').addEventListener('click',()=>{if(isExam()||submitted())return;if(state().running_since)pauseTimer(current);else state().running_since=Date.now();persist();updateTimer();});
  $('tasks').addEventListener('input',e=>{const input=e.target;if(input.dataset.taskSeek&&!isExam()){const t=tasks().find(t=>t.id===input.dataset.taskSeek),w=audioWindow(t);if(!w)return;const p=w.start_ms+Number(input.value);attempt.media.training_positions[t.id]=p;if(playingTask===t.id)$('exam-audio').currentTime=p/1000;persist();audioControls();return;}capture(e);});
  $('tasks').addEventListener('change',capture);
  $('tasks').addEventListener('click',e=>{if(isExam())return;const b=e.target.closest('[data-task-play]');if(b){playTraining(tasks().find(t=>t.id===b.dataset.taskPlay));return;}const o=e.target.closest('[data-task-occurrence]');if(o){const t=tasks().find(t=>t.id===o.dataset.taskOccurrence),occurrence=audioWindow(t)?.occurrences[Number(o.dataset.occurrence)];if(occurrence)playTraining(t,occurrence.start_ms);}});
  $('exam-audio-start').addEventListener('click',startExamAudio);const a=$('exam-audio');
  a.addEventListener('timeupdate',()=>{if(!attempt.mode)return;if(isExam()){if(attempt.media.exam_audio.started)attempt.media.exam_audio.position_ms=Math.max(attempt.media.exam_audio.position_ms??0,a.currentTime*1000);}else if(playingTask){attempt.media.training_positions[playingTask]=a.currentTime*1000;if(playingEnd&&a.currentTime*1000>=playingEnd){a.pause();attempt.media.training_positions[playingTask]=playingEnd;playingEnd=null;}}audioControls();if(Date.now()-lastAudioSave>1000){persist();lastAudioSave=Date.now();}});
  a.addEventListener('pause',audioControls);a.addEventListener('play',audioControls);a.addEventListener('loadedmetadata',()=>{if(isExam()&&attempt.media.exam_audio.started)a.currentTime=Math.min(a.duration,attempt.media.exam_audio.position_ms/1000);audioControls();});
  a.addEventListener('ended',()=>{if(isExam()){attempt.media.exam_audio.finished=true;attempt.media.exam_audio.position_ms=a.duration*1000;persist();}audioControls();});
  $('submit-section').addEventListener('click',()=>submitSection());$('export-attempt').addEventListener('click',exportAttempt);
  $('reset-attempt').addEventListener('click',async()=>{if(!await confirmAction('Rozpocząć nową próbę?','Zapisane na tym urządzeniu odpowiedzi zostaną usunięte. Ponownie wybierzesz tryb treningu lub symulacji.', 'Rozpocznij od nowa'))return;a.pause();a.currentTime=0;playingTask=null;playingEnd=null;attempt=createAttempt(exam,fingerprint);current=sections()[0].id;persist();renderSetup();window.scrollTo({top:0});});
  window.addEventListener('beforeunload',()=>{if(!attempt.mode)return;if(!isExam())pauseTimer(current);else if(attempt.media.exam_audio.started)attempt.media.exam_audio.position_ms=Math.max(attempt.media.exam_audio.position_ms??0,a.currentTime*1000);persist();});
}
async function start(){
  const response=await fetch('/exam.json',{cache:'no-cache'});if(!response.ok)throw new Error(`Nie udało się wczytać arkusza (HTTP ${response.status}).`);const text=await response.text();exam=JSON.parse(text);if(!Array.isArray(exam.sections)||!exam.id)throw new Error('Niepoprawny plik egzaminu.');
  exam.sections.sort((a,b)=>a.position-b.position);for(const s of exam.sections)s.tasks?.sort((a,b)=>a.position-b.position);const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text));fingerprint=[...new Uint8Array(digest)].map(b=>b.toString(16).padStart(2,'0')).join('');key=`proba:${exam.id}:${exam.revision??1}:${fingerprint}`;attempt=createAttempt(exam,fingerprint);
  try{const saved=JSON.parse(localStorage.getItem(key)??'null');if(saved?.exam_id===exam.id&&saved.package_fingerprint===fingerprint&&saved.answers&&saved.sections&&saved.selected_tasks&&[null,'training','exam'].includes(saved.mode))attempt=saved;}catch{}
  attempt.media??={exam_audio:{started:false,finished:false,position_ms:0},training_positions:{}};attempt.media.exam_audio??={started:false,finished:false,position_ms:0};attempt.media.training_positions??={};current=sections().some(s=>s.id===attempt.current_section_id)?attempt.current_section_id:sections()[0].id;
  try{const r=await fetch('/audio.json',{cache:'no-cache'});if(r.ok)audioData=await r.json();}catch{}
  const url=sourceUrl(source('audio'));if(url)$('exam-audio').src=url;$('exam-audio').controls=false;$('exam-label').textContent=`${exam.level} · ${exam.session?.label??exam.title}`;document.title=`${exam.level} · ${exam.session?.label??'Egzamin'} — Próba`;
  $('loading').hidden=true;$('export-attempt').disabled=!attempt.mode;events();renderSection();persist();setInterval(()=>{updateTimer();if(isExam()&&!submitted()&&section().time_limit_seconds&&secondsElapsed(state())>=section().time_limit_seconds)submitSection(true);},1000);
}
start().catch(e=>{$('loading').hidden=true;$('error').hidden=false;$('error').textContent=e.message;});
