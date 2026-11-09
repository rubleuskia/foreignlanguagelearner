'use strict';
const $ = id => document.getElementById(id);
const csrf = document.querySelector('meta[name="control-token"]').content;
let state = {jobs:[],tags:[]}, selectedOperation = null, initialized = false, statusBusy = false;
const labels = {queued:'В очереди',running:'Выполняется',ready:'Готов к деплою',consumed:'Использован',passed:'Пройдено',failed:'Ошибка',warning:'Требует внимания',interrupted:'Прервано',skipped:'Пропущено'};
const actions = {refresh:'Обновление тегов',prepare:'Подготовка версии',deploy:'Деплой версии',tests:'Проверки API'};
const color = s => ({passed:'good',ready:'good',failed:'bad',warning:'warn',interrupted:'warn',running:'busy',queued:'busy'}[s] || 'neutral');
function element(tag, text, cls) { const e=document.createElement(tag); if(text!=null)e.textContent=text; if(cls)e.className=cls; return e; }
function pill(s, text) { return element('span',text || labels[s] || s,'pill '+color(s)); }
function date(v) { return v ? new Date(v).toLocaleString('ru-RU',{day:'2-digit',month:'short',hour:'2-digit',minute:'2-digit'}) : '—'; }
function notice(text) { $('notice').textContent=text; $('notice').hidden=!text; }
async function api(path, body) {
  const response=await fetch(path,{method:body ? 'POST':'GET',headers:body ? {'Content-Type':'application/json','X-Control-Token':csrf}:{},body:body ? JSON.stringify(body):undefined});
  const data=await response.json(); if(!response.ok)throw Error(data.error || 'Не удалось выполнить запрос.'); return data;
}
function tab(id) {
  document.querySelectorAll('.page').forEach(p=>p.hidden=p.id!==id);
  document.querySelectorAll('[data-tab]').forEach(b=>{if(b.dataset.tab===id)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});
  $('operation-detail').hidden=true;
  window.scrollTo({top:0,behavior:'instant'});
}
document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>tab(b.dataset.tab));
document.querySelectorAll('[data-goto]').forEach(b=>b.onclick=()=>tab(b.dataset.goto));
function rows(target, data, render, empty) {
  const box=$(target); box.replaceChildren(); box.className=data.length ? 'rows':'rows empty';
  if(!data.length)box.textContent=empty; else data.forEach(x=>box.append(render(x)));
}
function row(title, subtitle, right) {
  const r=element('div',null,'row'), left=element('div'); left.append(element('div',title,'row-title'));
  if(subtitle)left.append(element('small',subtitle));r.append(left);if(right)r.append(right);return r;
}
function button(text, fn, cls='text-button') { const b=element('button',text,cls);b.onclick=fn;return b; }
function showOperation(id) {selectedOperation=id;renderOperation();$('operation-detail').hidden=false;$('operation-detail').scrollIntoView({behavior:'smooth',block:'start'});}
$('close-operation').onclick=()=>{$('operation-detail').hidden=true;selectedOperation=null;};
function renderOperation() {
  if(!selectedOperation)return;const job=state.jobs.find(j=>j.id===selectedOperation);if(!job)return;
  $('operation-title').textContent=(actions[job.action] || job.action)+(job.tag ? ' · '+job.tag:'');
  const summary=$('operation-summary');summary.replaceChildren(pill(job.state));
  summary.append(element('p',job.error || job.warning || (job.state==='ready' ? 'Просмотрите изменения в журнале. Деплой этого плана изменит prod.' : 'Начало: '+date(job.created_at))));
  if(job.ci_url){const a=element('a','Успешный CI ↗');a.href=job.ci_url;a.target='_blank';a.rel='noopener noreferrer';summary.append(a);}
  if(job.report)renderCases(summary,job.report);
  $('operation-log').textContent=job.log || 'Журнал ещё пуст.';
}
function renderCases(box,report) {
  report.cases.forEach(c=>box.append(row(c.name,c.detail || (c.http ? 'HTTP '+c.http+' · '+c.latency_ms+' мс':''),pill(c.state))));
  for(const r of report.requests || [])box.append(row('Ключ запроса · '+r.kind,r.key+' · '+(r.request_id || 'ответ POST не получен'),pill(r.state)));
}
function operationRow(job) {
  const right=element('div',null,'row-actions');right.append(pill(job.state),button('Журнал ↗',()=>showOperation(job.id)));
  return row(actions[job.action]+(job.tag ? ' · '+job.tag:''),date(job.created_at)+(job.error ? ' · '+job.error:''),right);
}
function renderState() {
  const operator=state.configuration?.deployment_mode==='operator';
  const compatible=operator ? state.tags.filter(r=>r.operator_supported) : state.tags;
  $('release-readiness').textContent=operator ? 'Первый этап · совместимых CI-тегов: '+compatible.length+(compatible.length ? '. Выберите версию ниже.' : '. Нужен новый тег после слияния первого этапа в main и успешного CI.') : 'Второй этап · Apple и подписки.';
  const picker=$('release-tag'), selected=picker.value;
  const placeholder=element('option',compatible.length ? 'Выберите тег релиза' : 'Нет тегов — нажмите «Получить теги»');placeholder.value='';
  picker.replaceChildren(placeholder,...compatible.map(r=>{const o=element('option',r.tag);o.value=r.tag;return o;}));
  picker.value=compatible.some(r=>r.tag===selected) ? selected : '';
  $('release-count').textContent='Доступно для выбранного этапа: '+compatible.length;
  rows('recent-operations',state.jobs.slice(0,4),operationRow,'Операций ещё не было');
  rows('operations',state.jobs,operationRow,'Операций ещё не было');
  rows('plans',state.jobs.filter(j=>j.action==='prepare' && j.state==='ready'),job=>{
    const right=element('div',null,'row-actions');right.append(button('Изменения ↗',()=>showOperation(job.id)));
    const b=button('Развернуть',()=>deploy(job),'primary operation-button');b.disabled=!!state.active;right.append(b);
    return row(job.tag,job.account_id+' · '+date(job.created_at)+' · '+job.sha.slice(0,12),right);
  },'Нет готовых планов. Получите теги и подготовьте выбранную версию.');
  const reportJob=state.jobs.find(j=>j.report && j.account_id===state.configuration?.account_id);
  if(reportJob) {
    const r=reportJob.report;const box=$('test-report');box.className='rows';box.replaceChildren();renderCases(box,r);
    $('test-report-time').textContent=date(reportJob.created_at);
    const failed=r.cases.filter(c=>c.state==='failed').length, skipped=r.cases.filter(c=>c.state==='skipped').length;
    const stale=Date.now()-new Date(reportJob.created_at).getTime()>15*60*1000;
    $('api-status').textContent=stale?'Нужно повторить':failed ? 'Есть ошибки':r.state==='passed' ? 'Пройдены':r.state==='warning' ? 'Частично проверено':'Проверяются';
    $('api-detail').textContent=(r.coverage==='inference'?'Со сквозным запросом':r.coverage==='authenticated'?'С авторизацией':'Только без авторизации')+' · '+date(reportJob.created_at);
    if(skipped)$('api-detail').textContent+=' · есть пропуски';
  }else{
    $('api-status').textContent='Не запускались';$('api-detail').textContent='Для текущего аккаунта нет отчёта';
    $('test-report').textContent='Для текущего аккаунта проверок ещё не было.';$('test-report').className='rows empty';$('test-report-time').textContent='—';
  }
  document.querySelectorAll('.operation-button').forEach(b=>b.disabled=!!state.active);
  renderOperation();
  if(!initialized){fillConfig(state.configuration);initialized=true;}
}
async function refreshState() {try{state=await api('/api/state');renderState();}catch(e){notice(e.message);}}
function stackName(name) {return ({'CloudFoundation':'Аккаунты и API','CloudBilling':'Подписки Apple','CloudTranslation':'Облачные переводы','PaidAlignment':'Обработка аудио','Operator':'Первый этап · API и Bedrock','OperatorAlignment':'Первый этап · аудио'})[name.replace('ForeignLanguageLearner','').replace('-prod','')] || name;}
async function refreshStatus() {
  if(statusBusy)return;statusBusy=true;
  try {
    const result=await api('/api/status');
    $('connection-note').hidden=!!result.stacks;
    $('connection-note').textContent=result.error || 'Подключите AWS, чтобы увидеть состояние продакшена.';
    if(!result.stacks){$('infra-status').textContent=result.configured?'Нет доступа':'Не подключено';$('infra-detail').textContent='Откройте «Настройка»';$('release-status').textContent='—';
      rows('client-outputs',[],()=>{},'Нет актуальных реквизитов из AWS');
      rows('stacks',[],()=>{},'Нет актуального состояния из AWS');rows('alarms',[],()=>{},'Нет актуальных данных из AWS');$('checked-at').textContent='—';return;}
    const stacks=result.stacks, installed=stacks.filter(s=>s.status!=='NOT_DEPLOYED');
    const outputs=stacks.find(s=>s.name==='ForeignLanguageLearnerOperator-prod')?.outputs || {};
    rows('client-outputs',Object.entries(outputs).filter(([key])=>['ApiUrl','UserPoolId','ClientId','OperatorUsername','BedrockModelId','AlarmTopicArn'].includes(key)),([key,value])=>row(({ApiUrl:'Адрес API',UserPoolId:'Cognito User Pool',ClientId:'Cognito Client ID',OperatorUsername:'Создайте пользователя с логином',BedrockModelId:'Модель Bedrock',AlarmTopicArn:'Тема оповещений SNS'})[key],value),'Реквизиты появятся после деплоя первого этапа.');
    const unhealthy=installed.some(s=>!['CREATE_COMPLETE','UPDATE_COMPLETE','UPDATE_ROLLBACK_COMPLETE','IMPORT_COMPLETE'].includes(s.status));
    $('infra-status').textContent=!installed.length?'Не развёрнуто':unhealthy?'Требует внимания':'Стеки доступны';
    $('infra-detail').textContent=result.account_id+' · '+installed.length+' компонентов';
    const tags=[...new Set(installed.map(s=>s.tags.ControlReleaseTag || 'Без метки'))];
    $('release-status').textContent=tags.length===1 ? tags[0]:tags.length>1 ? 'Разные ревизии':'—';
    $('release-detail').textContent=tags.length>1 ? 'Проверьте метки каждого компонента':'По меткам CloudFormation';
    $('checked-at').textContent=date(result.checked_at);
    rows('stacks',stacks,s=>{const ok=['CREATE_COMPLETE','UPDATE_COMPLETE','IMPORT_COMPLETE'].includes(s.status);return row(stackName(s.name),(s.tags.ControlReleaseTag || 'Без тега')+' · '+s.status,pill(s.status==='NOT_DEPLOYED'?'skipped':ok?'passed':'warning',s.status==='NOT_DEPLOYED'?'Не развёрнуто':s.status==='UPDATE_ROLLBACK_COMPLETE'?'Изменения отменены':ok?'Доступен':'Проверить'));},'Стеков нет');
    rows('alarms',result.alarms,a=>row(a.name,null,pill(a.state==='OK'?'passed':a.state==='ALARM'?'failed':'warning',a.state==='OK'?'В норме':a.state==='ALARM'?'Тревога':'Мало данных')),'Нет зарегистрированных сигналов. Это не подтверждение исправности API.');
  }catch(e){notice(e.message);}finally{statusBusy=false;}
}
async function start(path, body) {try{notice('');const job=await api(path,body);await refreshState();showOperation(job.id);}catch(e){notice(e.message);}}
$('refresh-status').onclick=refreshStatus;
$('refresh-tags').onclick=()=>start('/api/refresh',{});
$('prepare').onclick=()=>{const tag=$('release-tag').value.trim();if(!tag)return notice('Выберите CI-тег из списка.');start('/api/prepare',{tag});};
$('smoke-tests').onclick=()=>start('/api/tests',{mode:'smoke'});
function confirm(title,description,expected,action) {
  const dialog=$('confirm-dialog');$('confirm-title').textContent=title;$('confirm-description').textContent=description;
  $('confirm-input').value='';$('confirm-expected').textContent='Введите: '+expected;$('confirm-action').disabled=true;
  $('confirm-input').oninput=()=>{$('confirm-action').disabled=$('confirm-input').value!==expected;};
  dialog.onclose=()=>{if(dialog.returnValue==='confirm' && $('confirm-input').value===expected)action(expected);};
  dialog.returnValue='cancel';dialog.showModal();
}
function deploy(plan) {confirm('Развернуть '+plan.tag+'?', 'Изменится prod в аккаунте '+plan.account_id+'. Проверьте изменения, особенно права IAM, замену и удаление ресурсов. Используется подготовленная сборка и зафиксированная конфигурация. Откат к старому тегу не восстанавливает данные.',plan.account_id+'/'+plan.tag,value=>start('/api/deploy',{plan_id:plan.id,confirm:value}));}
$('inference-tests').onclick=()=>confirm('Запустить сквозной тест?', 'Будут созданы до двух новых запросов к платной модели для тестового подписчика. Повтор того же ключа должен вернуть тот же результат. Прерванная операция не запускается повторно автоматически.','2',value=>start('/api/tests',{mode:'inference',confirm:value}));
function updateMode() {const operator=$('deployment-mode').value==='operator';$('operator-settings').hidden=!operator;$('subscription-settings').hidden=operator;}
$('deployment-mode').onchange=updateMode;
$('check-readiness').onclick=async()=>{const b=$('check-readiness');b.disabled=true;try{const r=await api('/api/readiness');rows('readiness-cases',r.cases,c=>row(c.name,c.detail,pill(c.state)),'Нет проверок');notice(r.note);}catch(e){notice(e.message);}finally{b.disabled=false;}};
function fillConfig(c) {
  c=c || {account_id:'',profile:'fll-prod',region:'eu-north-1',context:{acceptTranslations:'false',paidAlignment:'false'}};
  $('deployment-mode').value=c.deployment_mode || 'subscription';
  const ctx=c.context || {};
  $('operator-username').value=ctx.operatorUsername || 'operator';$('daily-model-limit').value=ctx.dailyModelLimit || '50';
  $('operator-alignment').value=ctx.operatorAlignment || 'true';$('worker-repository').value=ctx.workerRepositoryName || '';
  $('worker-digest').value=ctx.workerImageDigest || '';$('benchmark-file').value=c.alignment_benchmark_file || '';updateMode();
  $('account-id').value=c.account_id;$('profile').value=c.profile;$('access-token-file').value=c.access_token_file || '';
  const extra={...c};delete extra.deployment_mode;delete extra.account_id;delete extra.profile;delete extra.region;delete extra.access_token_file;
  $('deploy-config').value=JSON.stringify(extra,null,2);
}
$('config-form').onsubmit=async event=>{event.preventDefault();try{
  const extra=JSON.parse($('deploy-config').value), c={...extra,account_id:$('account-id').value.trim(),profile:$('profile').value.trim(),region:$('region').value};
  c.deployment_mode=$('deployment-mode').value;
  if(c.deployment_mode==='operator'){c.context={operatorUsername:$('operator-username').value.trim(),dailyModelLimit:$('daily-model-limit').value,operatorAlignment:$('operator-alignment').value};
    if($('worker-repository').value.trim())c.context.workerRepositoryName=$('worker-repository').value.trim();
    if($('worker-digest').value.trim())c.context.workerImageDigest=$('worker-digest').value.trim();
    delete c.apple_roots;delete c.root_sha256;delete c.policy_file;delete c.alignment_benchmark_file;
    if($('benchmark-file').value.trim())c.alignment_benchmark_file=$('benchmark-file').value.trim();}
  if($('access-token-file').value.trim())c.access_token_file=$('access-token-file').value.trim();
  await api('/api/config',c);notice('Настройки сохранены. Проверяю подключение к AWS.');await refreshState();await refreshStatus();
}catch(e){notice(e.message);}};
api('/api/profiles').then(d=>$('profiles').replaceChildren(...d.profiles.map(p=>{const o=element('option');o.value=p;return o;}))).catch(()=>{});
refreshState();refreshStatus();setInterval(refreshState,3000);setInterval(refreshStatus,30000);
