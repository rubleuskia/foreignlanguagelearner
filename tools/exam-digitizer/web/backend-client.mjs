/** Backend transport retained for the future web client. No exam keys or tokens are stored. */
export class ExamBackendClient {
  constructor({baseURL, accessToken, fetchImpl=globalThis.fetch}) {
    this.base=new URL(baseURL);
    if(this.base.username||this.base.password||this.base.search||this.base.hash||
       !(this.base.protocol==='https:'||(this.base.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(this.base.hostname))))
      throw new Error('Invalid exam API address');
    this.token=accessToken;this.fetch=fetchImpl;
  }
  async request(path,{method='GET',body,signal}={}) {
    if(!/^v1\/(?:exams|exam-attempts|exam-assessments)(?:\/|$)/.test(path)||path.includes('..')||/[?#\\]/.test(path))
      throw new Error('Invalid exam API path');
    const token=await this.token();
    if(typeof token!=='string'||!token)throw new Error('Sign in to use exams');
    const response=await this.fetch(new URL(path,this.base.href.replace(/\/?$/,'/')),{method,signal,
      credentials:'omit',redirect:'error',cache:'no-store',
      headers:{Authorization:`Bearer ${token}`,...(body===undefined?{}:{'Content-Type':'application/json'})},
      ...(body===undefined?{}:{body:JSON.stringify(body)})});
    const value=await response.json();
    if(!response.ok){const error=new Error(value.error?.code??value.error??'Exam service unavailable');error.status=response.status;error.payload=value;throw error;}
    return value;
  }
  catalog(options){return this.request('v1/exams',options);}
  package(id,revision,options){return this.request(`v1/exams/${encodeURIComponent(id)}/revisions/${encodeURIComponent(revision)}`,options);}
  attempts(options){return this.request('v1/exam-attempts',options);}
  createAttempt(body,options){return this.request('v1/exam-attempts',{...options,method:'POST',body});}
  updateAttempt(id,body,options){return this.request(`v1/exam-attempts/${encodeURIComponent(id)}`,{...options,method:'PUT',body});}
  submitAttempt(id,body,options){return this.request(`v1/exam-attempts/${encodeURIComponent(id)}/submit`,{...options,method:'POST',body});}
}
