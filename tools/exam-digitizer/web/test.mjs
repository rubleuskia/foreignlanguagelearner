import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {activeTasks,createAttempt,examResumePosition,gradeItem,gradeSection,normalizeText,secondsElapsed,trainingAudioWindow} from './logic.mjs';
import {ExamBackendClient} from './backend-client.mjs';

const requests=[];
const backend=new ExamBackendClient({baseURL:'https://api.example.test',accessToken:async()=> 'synthetic-token',
  fetchImpl:async(url,options)=>{requests.push({url:String(url),options});return {ok:true,json:async()=>({exams:[]})};}});
await backend.catalog();
await backend.updateAttempt('attempt',{base_version:2,change_id:'fixed-id',responses:{a:'answer'}});
assert.equal(requests[0].url,'https://api.example.test/v1/exams');
assert.equal(requests[0].options.credentials,'omit');
assert.equal(requests[0].options.redirect,'error');
assert.equal(requests[1].options.method,'PUT');
assert.equal(JSON.parse(requests[1].options.body).base_version,2);
await assert.rejects(()=>backend.request('v1/exams/../../private'));
assert.throws(()=>new ExamBackendClient({baseURL:'http://untrusted.example',accessToken:async()=>''}));
let calls=0;
const conflict=new ExamBackendClient({baseURL:'https://api.example.test',accessToken:async()=> 'synthetic-token',
  fetchImpl:async()=>{calls++;return {ok:false,status:409,json:async()=>({error:'EXAM_ATTEMPT_CONFLICT'})};}});
await assert.rejects(()=>conflict.updateAttempt('attempt',{}),e=>e.status===409);
assert.equal(calls,1);

const choice = {id:'a', max_score_units:50, grading:{mode:'exact',accepted_answers:['option-b']}};
assert.equal(gradeItem(choice,'option-b').score_units,50);
assert.equal(gradeItem(choice,'option-a').score_units,0);
assert.equal(gradeItem(choice,undefined).status,'unanswered');
const set = {max_score_units:200, grading:{mode:'set',accepted_answers:[['one','two']]}};
assert.equal(gradeItem(set,['two','one']).status,'correct');
assert.equal(gradeItem(set,['one']).status,'incorrect');
const polish = {max_score_units:50, grading:{mode:'exact',accepted_answers:['Łódź']}};
assert.equal(gradeItem(polish,' Łódź ').status,'correct');
assert.equal(gradeItem(polish,'Lodz').status,'incorrect');
assert.equal(gradeItem(polish,'łódź').status,'incorrect');
assert.equal(gradeItem({...polish,grading:{...polish.grading,ignore_case:true}},'łódź').status,'correct');
assert.equal(normalizeText('s\u0301'), 'ś');
const ai = {id:'b',max_score_units:100,grading:{mode:'ai_stub',reference_answer:'przykład'}};
assert.equal(gradeItem(ai,'inna poprawna odpowiedź').score_units,null);
assert.equal(gradeItem(ai,undefined).score_units,null);
assert.equal(gradeItem(ai,undefined).status,'pending');
const section = {max_score_units:150,tasks:[{id:'I',items:[choice,ai]}]};
const result = gradeSection(section,{a:'option-b',b:'odpowiedź'});
assert.equal(result.score_units,null);
assert.equal(result.total_score_units,null);
assert.equal(result.objective_score_units,50);
assert.equal(result.pending_score_units,100);
assert.equal(result.responses.b.score_units,null);
const writing = {max_score_units:3000,selection:{mode:'choose_one'},tasks:[{id:'I',max_score_units:3000,items:[{id:'w1',max_score_units:null,grading:{mode:'ai_stub'}},{id:'w2',max_score_units:null,grading:{mode:'ai_stub'}}]},{id:'II',max_score_units:3000,items:[{id:'w3',max_score_units:null,grading:{mode:'ai_stub'}}]}]};
assert.equal(activeTasks(writing,'I').length,1);
assert.equal(gradeSection(writing,{w1:'tekst',w2:'tekst',w3:'z innego zestawu'},'I').pending_score_units,3000);
assert.equal(gradeSection(writing,{w1:'tekst'},'I').total,2);
assert.equal(gradeSection(writing,{},'I').pending_score_units,3000);
assert.equal(gradeSection(writing,{},'I').total_score_units,null);
assert.equal(secondsElapsed({elapsed_seconds:10,running_since:1000},6000),15);
console.log('PASS: exact, sets, Polish diacritics, AI pending, writing selection, grouped rubric, timer.');

const membership={max_score_units:200,grading:{mode:'token_membership',accepted_answers:['2','4'],token_pattern:'[0-9]+',max_tokens:2}};
assert.equal(gradeItem(membership,'4 ; 2').score_units,200);
assert.equal(gradeItem(membership,'2 / 2 / 4').score_units,200);
assert.equal(gradeItem(membership,'2, 3').score_units,100);
assert.equal(gradeItem(membership,'24').score_units,0);
assert.equal(gradeItem(membership,'1 2 3 4 5').status,'invalid');
assert.equal(gradeItem(membership,'1 2 3 4 5').score_units,0);
assert.equal(gradeItem(membership,'٢ ٤').score_units,0);
assert.equal(createAttempt({id:'exam',revision:2},'fingerprint').mode,null);
assert.deepEqual(trainingAudioWindow([{start_ms:1000,end_ms:5000},{start_ms:7000,end_ms:11000}]),{start_ms:1000,end_ms:11000,occurrences:[{start_ms:1000,end_ms:5000},{start_ms:7000,end_ms:11000}]});
assert.equal(examResumePosition({started:true,finished:false,position_ms:120000},600000),120000);
assert.equal(examResumePosition({started:true,finished:true,position_ms:600000},600000),null);
assert.equal(examResumePosition({started:true,finished:false,position_ms:600000},600000),null);
assert.equal(examResumePosition({started:false,finished:false,position_ms:0},600000),0);
console.log('PASS: raw token partial scoring, deduplication, anti-guess limit, ASCII digits, mode selection, training repeats and exam resume.');

if (process.argv[2]) {
  const profile = JSON.parse(readFileSync(process.argv[2], 'utf8'));
  let objectiveCount = 0, aiCount = 0, totalCount = 0;
  for (const section of profile.sections) {
    const knownAnswers = {};
    for (const task of section.tasks ?? []) {
      const options = new Set((task.options ?? []).map(option => option.id));
      const ids = new Set((task.items ?? []).map(item => item.id));
      for (const block of task.blocks ?? []) {
        for (const match of String(block.text ?? '').matchAll(/\{\{([^}]+)\}\}/gu)) assert.ok(ids.has(match[1]),`Unknown gap ${match[1]}`);
      }
      for (const item of task.items ?? []) {
        totalCount += 1;
        assert.ok(['single_choice','multi_choice','text','long_text'].includes(item.response_type),`${item.id} has unsupported response type`);
        for (const id of item.option_ids ?? []) assert.ok(options.has(id),`${item.id} points to missing option ${id}`);
        if (item.underlined_text) assert.ok(`${item.prompt}\n${item.context ?? ''}`.includes(item.underlined_text),`${item.id} missing underlined text`);
        if (['exact','set','token_membership'].includes(item.grading.mode)) {
          objectiveCount += 1;
          assert.ok(item.grading.accepted_answers.length,`${item.id} has no answer`);
          const value = item.grading.mode==='token_membership'?item.grading.accepted_answers.join(', '):item.grading.accepted_answers[0];
          knownAnswers[item.id] = value;
          assert.equal(gradeItem(item,value).score_units,item.max_score_units,`${item.id} does not accept its official answer`);
          if (item.response_type.includes('choice')) for (const option of Array.isArray(value) ? value : [value]) assert.ok(options.has(option),`${item.id} key points to missing option`);
        } else {
          aiCount += 1;
          assert.equal(gradeItem(item,undefined).score_units,null,`${item.id} empty AI response invented a score`);
        }
      }
    }
    const selected = section.selection?.mode === 'choose_one' ? section.tasks[0]?.id : undefined;
    const result = gradeSection(section,knownAnswers,selected);
    assert.equal(result.objective_score_units,result.auto_max_score_units,`${section.id} objective full score mismatch`);
    if (result.pending_count) assert.equal(result.total_score_units,null);
  }
  console.log(`PASS real profile: ${totalCount} items; ${objectiveCount} official objective answers; ${aiCount} AI placeholders; options, gaps and underlining valid.`);
}
