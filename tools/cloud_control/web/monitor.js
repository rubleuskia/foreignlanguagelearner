'use strict';
const monitorState={active:null,data:{},sequence:{},configuration:null,operation:null};
const monitorLabels={awaiting_upload:'Ожидает загрузки',uploaded:'Файлы загружены',queued:'В очереди',starting:'Запуск',running:'Выполняется',downloading:'Получение файлов',preparing:'Подготовка',aligning:'Alignment',validating:'Проверка',publishing:'Сохранение',succeeded:'Готово',succeeded_with_review:'Нужна проверка',failed:'Ошибка',cancelled:'Отменено',expired:'Истёк срок'};
function monitorBytes(value){if(value==null)return '—';if(value<1000)return value+' Б';const units=['КБ','МБ','ГБ','ТБ'];let n=value/1000,i=0;while(n>=1000 && i<units.length-1){n/=1000;i++;}return n.toLocaleString('ru-RU',{maximumFractionDigits:2})+' '+units[i];}
function monitorDuration(value){if(value==null)return '—';const seconds=Math.round(value);return seconds>=3600?Math.floor(seconds/3600)+' ч '+Math.floor(seconds%3600/60)+' мин':seconds>=60?Math.floor(seconds/60)+' мин '+seconds%60+' с':seconds+' с';}
function monitorMoney(value,currency){if(value==null)return 'Нет данных';const amount=Number(value);return (Math.abs(amount)<.00005?0:amount).toLocaleString('ru-RU',{style:'currency',currency:currency || 'USD',maximumFractionDigits:Math.abs(amount)<1?4:2});}
function monitorCard(label,value,detail){const box=element('article',null,'metric');box.append(element('span',label,'metric-label'),element('strong',value),element('span',detail || '','muted'));return box;}
function monitorTable(headers,records){const table=element('table',null,'data-table'),head=element('thead'),tr=element('tr');headers.forEach(h=>tr.append(element('th',h)));head.append(tr);table.append(head);const body=element('tbody');records.forEach(values=>{const line=element('tr');values.forEach(value=>{const cell=element('td');cell.append(value instanceof Node?value:document.createTextNode(value==null?'—':String(value)));line.append(cell);});body.append(line);});table.append(body);return table;}
function monitorWarnings(data){return (data.warnings || []).map(w=>w.source+': '+w.error).join(' · ');}
function monitorOptions(id,items,selected){$(id).replaceChildren(...items.map(item=>{const option=element('option',item.label);option.value=item.value;return option;}));$(id).value=selected || '';}
function monitorParams(values){const query=new URLSearchParams();Object.entries(values).forEach(([key,value])=>{if(value!==undefined && value!==null && value!=='')query.set(key,value);});return query.size?'?'+query:'';}
function monitorFailure(kind,message){
  const targets={storage:['storage-note','storage-files'],alignment:['alignment-note','alignment-jobs'],costs:['cost-note','cost-services'],errors:['error-note','error-events'],deployment:['deployment-summary','deployment-components']}[kind];
  $(targets[0]).textContent=message;$(targets[1]).replaceChildren();
  if(kind==='storage'){$('storage-more').hidden=true;$('storage-summary').replaceChildren();}
  if(kind==='alignment')$('alignment-metrics').replaceChildren(monitorCard('Запросы','Недоступно','Проверьте профиль и права DynamoDB'));
  if(kind==='costs'){$('cost-metrics').replaceChildren(monitorCard('За текущий месяц','Недоступно','Нужен доступ к Cost Explorer'));$('cost-daily').replaceChildren();}
  if(kind==='errors'){$('error-metrics').replaceChildren(monitorCard('HTTP 5xx','Недоступно','Проверьте CloudWatch и Logs'));$('errors-more').hidden=true;}
  if(kind==='deployment')$('deployment-changes').replaceChildren();
}
async function loadMonitor(kind,more=false){
  const sequence=(monitorState.sequence[kind] || 0)+1;monitorState.sequence[kind]=sequence;
  let path;
  if(kind==='storage')path='/api/storage'+monitorParams({bucket:$('storage-bucket').value,prefix:$('storage-prefix').value,cursor:more?monitorState.data.storage?.cursor:null});
  if(kind==='alignment')path='/api/alignment-usage'+monitorParams({days:$('alignment-days').value});
  if(kind==='costs')path='/api/costs';
  if(kind==='errors')path='/api/errors'+monitorParams({group:$('error-group').value,hours:$('error-hours').value,cursor:more?monitorState.data.errors?.cursor:null});
  if(kind==='deployment')path='/api/deployment-summary'+monitorParams({tag:$('release-tag').value});
  const refresh=$('refresh-'+kind);if(refresh)refresh.disabled=true;
  try{
    const data=await api(path);if(sequence!==monitorState.sequence[kind])return;
    if(!data.available)throw Error(data.error || 'Нет данных из AWS.');
    if(more && kind==='storage')data.files=[...(monitorState.data.storage?.files || []),...data.files];
    monitorState.data[kind]=data;
    ({storage:renderStorage,alignment:renderAlignment,costs:renderCosts,errors:renderErrors,deployment:renderDeployment})[kind](data);
  }catch(error){if(sequence===monitorState.sequence[kind])monitorFailure(kind,error.message);}finally{if(refresh && sequence===monitorState.sequence[kind])refresh.disabled=false;}
}
function renderStorage(data){
  monitorOptions('storage-bucket',data.buckets.map(b=>({value:b.id,label:b.id})),data.bucket?.id);
  $('storage-note').textContent=data.scope?data.scope+' · '+date(data.checked_at)+(monitorWarnings(data)?' · '+monitorWarnings(data):''):'S3-хранилище ещё не найдено. Проверьте деплой и права CloudFormation.';
  const bytes=data.files.reduce((sum,file)=>sum+file.bytes,0);
  $('storage-summary').replaceChildren(element('strong','Показано '+data.files.length+' файлов · '+monitorBytes(bytes)));
  $('storage-files').replaceChildren(data.files.length?monitorTable(['Файл','Размер','Изменён','Класс'],data.files.map(file=>[file.key,monitorBytes(file.bytes),date(file.modified_at),file.storage_class])):element('p',data.bucket?'Нет файлов с этим префиксом.':'Нет доступных bucket.','empty'));
  $('storage-more').hidden=!data.cursor;
}
function renderAlignment(data){
  const hasSources=data.sources.length>0;
  $('alignment-metrics').replaceChildren(monitorCard('Запросы',hasSources?data.requests:'—','За '+data.days+' дней по дате создания'),monitorCard('Запуски worker',hasSources?data.executions:'—','Включая повторные попытки'),monitorCard('Среднее время',monitorDuration(data.mean_runtime_seconds),data.duration_samples+' завершённых с известным временем'),monitorCard('95% завершённых ≤',monitorDuration(data.p95_runtime_seconds),monitorBytes(data.input_bytes)+' входных данных'));
  $('alignment-time').textContent=date(data.checked_at);
  $('alignment-note').textContent=(!hasSources?'Таблица alignment не найдена; возможно, эта версия ещё не развёрнута. ':!data.complete?'Отчёт неполный. ':'')+data.scope+' '+data.duration_note+(monitorWarnings(data)?' · '+monitorWarnings(data):'');
  $('alignment-jobs').replaceChildren(data.jobs.length?monitorTable(['Задача / создана','Статус','Вход','Попытки','В очереди','Обработка'],data.jobs.map(job=>{
    const title=element('div');title.append(element('strong',job.title),element('small',date(new Date(job.created_at*1000).toISOString())+' · '+job.job_id));
    const status=pill(job.status==='failed'?'failed':job.status.startsWith('succeeded')?'passed':'running',monitorLabels[job.status] || job.status);
    if(job.error_code)status.title=job.error_code;
    return [title,status,job.input_kind+' · '+monitorBytes(job.input_bytes),job.attempts,monitorDuration(job.queue_seconds),monitorDuration(job.runtime_seconds)];
  })):element('p','В сохранённых записях выбранного периода задач нет.','empty'));
}
function renderCosts(data){
  $('cost-metrics').replaceChildren(monitorCard('Текущий месяц',monitorMoney(data.total,data.currency),data.start+' → '+data.end_exclusive+' (конец не включён)'),monitorCard('Сервисы',data.services.length,data.estimated?'Данные ещё уточняются':'Данные Cost Explorer'),monitorCard('Получено',date(data.checked_at),'Кэш 15 минут'));
  if(data.plan){$('cost-metrics').append(monitorCard('План AWS',data.plan.type || '—',data.plan.status || ''),monitorCard('Остаток кредитов',monitorMoney(data.plan.remaining_credits,data.plan.currency),data.plan.expires_at?'Действуют до '+date(data.plan.expires_at):'По данным AWS Free Tier'));}
  $('cost-note').textContent=data.scope+' '+data.note+(monitorWarnings(data)?' · '+monitorWarnings(data):'');
  rows('cost-services',data.services,s=>row(s.name,null,element('strong',monitorMoney(s.amount,data.currency))),'Cost Explorer ещё не вернул расходы. Это не подтверждение нулевого счёта.');
  const chart=$('cost-daily');chart.replaceChildren();const max=Math.max(...data.daily.map(day=>Math.abs(Number(day.amount))),.000001);
  for(const day of data.daily){const line=element('div',null,'cost-day'),bar=element('meter');bar.min=0;bar.max=max;bar.value=Math.abs(Number(day.amount));bar.title=monitorMoney(day.amount,data.currency);line.append(element('span',day.date.slice(5)),bar,element('strong',monitorMoney(day.amount,data.currency)));chart.append(line);}
  if(!data.daily.length)chart.append(element('p','Пока нет дневных данных.','empty'));
}
function renderErrors(data){
  $('error-metrics').replaceChildren(...data.metrics.map(metric=>monitorCard('HTTP 5xx · '+metric.api_id,metric.errors_5xx==null?'Нет данных':metric.errors_5xx,metric.requests==null?'Счётчик запросов не найден':metric.requests+' запросов за '+data.hours+' ч')));
  if(!data.metrics.length)$('error-metrics').append(monitorCard('HTTP 5xx','—','API Gateway не найден'));
  monitorOptions('error-group',data.groups.map(group=>({value:group.id,label:stackName(group.stack)+' · '+group.logical_id})),data.group?.id);
  $('error-note').textContent=data.scope+' · '+date(data.checked_at)+(monitorWarnings(data)?' · '+monitorWarnings(data):'');
  rows('error-events',data.events,item=>{const box=element('div',null,'log-event');box.append(element('small',date(new Date(item.timestamp).toISOString())+' · '+(item.stream || '')),element('pre',item.message));return box;},data.group?'На этой странице сообщений не найдено. При наличии следующей страницы продолжите просмотр.':'Группы логов пока не найдены.');
  $('errors-more').hidden=!data.cursor;
}
window.renderResourceChanges=function(changes){
  const box=element('div',null,'resource-summary');box.append(element('h3','Изменения подготовленного плана'));
  if(!changes.length){box.append(element('p','Изменений ресурсов в шаблонах не найдено.'));return box;}
  box.append(monitorTable(['Действие','Ресурс','Компонент','Изменяемые поля'],changes.map(change=>[
    pill(change.action==='remove'?'warning':change.action==='add'?'passed':'running',({add:'Добавить',modify:'Изменить',remove:'Удалить'})[change.action]),
    change.type+' · '+change.logical_id,stackName(change.stack),change.retained?'Ресурс сохранится (Retain)':change.changed_fields.join(', ') || '—'])));
  box.append(element('p','Возможность замены ресурсов и изменения IAM проверьте в полном CDK diff в журнале плана.','hint'));return box;
};
function renderDeployment(data){
  const box=$('deployment-summary');box.className='rows';box.replaceChildren();
  for(const installed of data.deployed)box.append(row(stackName(installed.name),installed.tag || 'Нет метки версии',pill(installed.status==='NOT_DEPLOYED'?'skipped':'passed',installed.status)));
  if(data.selected){const actions=element('div',null,'row-actions');actions.append(button('Выбрать этот тег',()=>{$('release-tag').value=data.selected.tag;loadMonitor('deployment');}));box.append(row('Кандидат: '+data.selected.tag,data.selected.sha.slice(0,12),actions));}
  for(const note of data.notes)box.append(element('p',note,'callout'));
  for(const comparison of data.comparisons)box.append(row(stackName(comparison.stack)+' · код выбранной версии',comparison.same_revision?'Эта ревизия уже развёрнута.':comparison.changed_files===null?'Нет локальной ревизии продакшена для сравнения.':comparison.changed_files.length?comparison.changed_files.slice(0,8).join(', ')+(comparison.changed_files.length>8?' …':''):'Отличий в backend/infra нет; настройки проверяются в плане.'));
  box.append(element('p',data.note,'hint'));
  rows('deployment-components',data.book_components,item=>row(item.name,item.in_selected_release?'Есть в выбранном теге':'В выбранном теге отсутствует',pill(item.deployed?'passed':'skipped',item.deployed?'Есть в AWS':'Нужен деплой')),'Нет данных.');
  const changes=$('deployment-changes');changes.replaceChildren();
  if(data.plan){changes.append(pill(data.plan.valid?'passed':'warning',data.plan.valid?'План актуален':'Подготовьте новый план'));for(const reason of data.plan.invalid_reasons || [])changes.append(element('p',reason,'callout'));changes.append(button('Открыть план '+data.plan.tag,()=>showOperation(data.plan.id)));if(data.plan.resource_changes)changes.append(window.renderResourceChanges(data.plan.resource_changes));else changes.append(element('p','Старый план без сводки ресурсов: подготовьте новый план.','hint'));}
  else changes.append(element('p','Выберите нужный тег и нажмите «Подготовить план», чтобы увидеть конкретные ресурсы AWS. Подготовка не разворачивает их.','hint'));
}
window.addEventListener('cloud-tab',event=>{monitorState.active=event.detail;const kind=event.detail==='releases'?'deployment':event.detail;if(['storage','alignment','costs','errors','deployment'].includes(kind))loadMonitor(kind);});
window.addEventListener('cloud-state',()=>{
  const configuration=JSON.stringify(state.configuration);const operation=state.jobs[0]?.id+':'+state.jobs[0]?.state;
  if(monitorState.configuration!==null && configuration!==monitorState.configuration){monitorState.data={};for(const key of Object.keys(monitorState.sequence))monitorState.sequence[key]++;$('storage-bucket').replaceChildren();$('error-group').replaceChildren();for(const kind of ['storage','alignment','costs','errors','deployment'])monitorFailure(kind,'Настройки проекта изменились. Получите актуальные данные.');const active=monitorState.active==='releases'?'deployment':monitorState.active;if(['storage','alignment','costs','errors','deployment'].includes(active))loadMonitor(active);}
  if(monitorState.active==='releases' && operation!==monitorState.operation)loadMonitor('deployment');
  monitorState.configuration=configuration;monitorState.operation=operation;
});
for(const kind of ['storage','alignment','costs','errors','deployment'])$('refresh-'+kind).onclick=()=>loadMonitor(kind);
$('storage-search').onclick=()=>loadMonitor('storage');$('storage-bucket').onchange=()=>loadMonitor('storage');$('storage-more').onclick=()=>loadMonitor('storage',true);
$('alignment-days').onchange=()=>loadMonitor('alignment');$('error-hours').onchange=()=>loadMonitor('errors');$('error-group').onchange=()=>loadMonitor('errors');$('errors-more').onclick=()=>loadMonitor('errors',true);
$('release-tag').onchange=()=>loadMonitor('deployment');
