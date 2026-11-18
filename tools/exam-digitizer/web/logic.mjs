export function normalizeText(value, policy = {}) {
  let text = String(value ?? '').normalize('NFC').trim();
  if (policy.collapse_whitespace) text = text.replace(/\s+/gu, ' ');
  if (policy.case_sensitive === false) text = text.toLocaleLowerCase('pl');
  if (policy.ignore_terminal_punctuation) text = text.replace(/[.!?]+$/u, '');
  return text;
}

export function isAnswered(value) {
  return Array.isArray(value) ? value.length > 0 : value !== undefined && value !== null && String(value).trim() !== '';
}

export function gradeItem(item, value) {
  const maximum = Number.isFinite(item.max_score_units) ? item.max_score_units : null;
  const grading = item.grading ?? {mode:'manual'};
  if (grading.mode === 'ai_stub' || grading.mode === 'manual') return {status:'pending', score_units:null, max_score_units:maximum, provider:'stub', answered:isAnswered(value)};
  if (!isAnswered(value)) return {status:'unanswered', score_units:0, max_score_units:maximum};
  if (grading.mode === 'token_membership') {
    const tokens=[...new Set(String(value).match(new RegExp(grading.token_pattern??'[0-9]+','gu'))??[])];
    const expected=[...new Set(grading.accepted_answers.map(String))];
    const maximumTokens=grading.max_tokens??item.selection?.max??expected.length;
    if(tokens.length>maximumTokens)return {status:'invalid',score_units:0,max_score_units:maximum,reason:'too_many_tokens',tokens};
    const correct=tokens.filter(token=>expected.includes(token)).length;
    const score=expected.length?Math.round((maximum??0)*correct/expected.length):0;
    return {status:correct===expected.length?'correct':correct>0?'partial':'incorrect',score_units:score,max_score_units:maximum,tokens,correct_tokens:correct};
  }
  let correct = false;
  if (grading.mode === 'set') {
    const actual = [...new Set(Array.isArray(value) ? value : [value])].sort();
    correct = (grading.accepted_answers ?? []).some(candidate => Array.isArray(candidate) && JSON.stringify([...new Set(candidate)].sort()) === JSON.stringify(actual));
  } else if (grading.mode === 'exact') {
    const policy = {...(grading.comparison_policy ?? grading.normalization ?? {})};
    if (grading.ignore_case === true) policy.case_sensitive = false;
    correct = (grading.accepted_answers ?? []).some(candidate => normalizeText(candidate, policy) === normalizeText(value, policy));
  } else return {status:'pending', score_units:null, max_score_units:maximum, provider:'unsupported_grading'};
  return {status:correct ? 'correct' : 'incorrect', score_units:correct ? (maximum ?? 0) : 0, max_score_units:maximum};
}

export function activeTasks(section, selectedTaskId) {
  const tasks = section.tasks ?? [];
  return section.selection?.mode === 'choose_one' ? tasks.filter(task => task.id === selectedTaskId) : tasks;
}

export function gradeSection(section, answers, selectedTaskId) {
  const tasks = activeTasks(section, selectedTaskId);
  const items = tasks.flatMap(task => task.items ?? []);
  const responses = {};
  let scored = 0, pending = 0, autoMaximum = 0, pendingCount = 0;
  for (const task of tasks) {
    const taskItems = task.items ?? [];
    const groupRubric = taskItems.some(item => !Number.isFinite(item.max_score_units));
    for (const item of taskItems) {
      const result = gradeItem(item, answers[item.id]);
      responses[item.id] = result;
      if (result.status === 'pending') pendingCount += 1;
      scored += result.score_units ?? 0;
      if (!groupRubric && result.status === 'pending') pending += result.max_score_units ?? 0;
      if (['exact','set','token_membership'].includes(item.grading?.mode)) autoMaximum += item.max_score_units ?? 0;
    }
    if (groupRubric && taskItems.some(item => responses[item.id].status === 'pending')) pending += task.max_score_units ?? 0;
  }
  return {score_units:pendingCount ? null : scored, total_score_units:pendingCount ? null : scored, objective_score_units:scored, max_score_units:section.max_score_units ?? 0, pending_score_units:pending, pending_count:pendingCount, auto_max_score_units:autoMaximum, answered:items.filter(item => isAnswered(answers[item.id])).length, total:items.length, responses};
}

export function secondsElapsed(timer, now = Date.now()) {
  return Math.max(0, (timer?.elapsed_seconds ?? 0) + (timer?.running_since ? (now - timer.running_since) / 1000 : 0));
}

export function formatDuration(seconds) {
  const value = Math.max(0, Math.ceil(seconds));
  return `${String(Math.floor(value / 60)).padStart(2,'0')}:${String(value % 60).padStart(2,'0')}`;
}

export function trainingAudioWindow(occurrences) {
  const valid=(occurrences??[]).filter(o=>Number.isFinite(o.start_ms)&&Number.isFinite(o.end_ms)&&o.end_ms>o.start_ms);
  return valid.length?{start_ms:Math.min(...valid.map(o=>o.start_ms)),end_ms:Math.max(...valid.map(o=>o.end_ms)),occurrences:valid}:null;
}

export function examResumePosition(media,durationMs) {
  if(media.finished)return null;
  const position=Math.max(0,media.position_ms??0);
  if(media.started&&Number.isFinite(durationMs)&&position>=durationMs)return null;
  return Number.isFinite(durationMs)?Math.min(position,durationMs):position;
}

export function points(units) {
  return new Intl.NumberFormat('pl-PL', {maximumFractionDigits:2}).format((units ?? 0) / 100);
}

export function createAttempt(exam, fingerprint) {
  return {schema_version:'1.0', exam_id:exam.id, revision:exam.revision??1, package_fingerprint:fingerprint, mode:null, started_at:null, updated_at:new Date().toISOString(), answers:{}, sections:{}, selected_tasks:{}, media:{exam_audio:{started:false,finished:false,position_ms:0},training_positions:{}}};
}
