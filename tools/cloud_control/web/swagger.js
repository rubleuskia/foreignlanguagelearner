'use strict';
const controlToken = document.querySelector('meta[name="control-token"]').content;
fetch('/api/openapi').then(async response => {
  const spec = await response.json();
  if (!response.ok) throw Error(spec.error || 'API пока недоступен. Проверьте настройки AWS.');
  const upstream=new URL(spec.servers[0].url);
  SwaggerUIBundle({spec, dom_id:'#swagger-ui', deepLinking:true, filter:true,
    validatorUrl:null, persistAuthorization:false, queryConfigEnabled:false,
    displayRequestDuration:true, showMutatedRequest:false, supportedSubmitMethods:['get','post'],
    requestInterceptor: request => {
      const target = new URL(request.url, location.href);
      if (target.origin !== upstream.origin || !/^\/v[12]\//.test(target.pathname)) throw Error('Разрешён только выбранный API.');
      const headers = Object.fromEntries(Object.entries(request.headers || {}).map(([key,value])=>[key.toLowerCase(),value]));
      const payload = {method:request.method.toUpperCase(), path:target.pathname+target.search,
        authorization:headers.authorization || null, idempotency_key:headers['idempotency-key'] || null,
        use_saved_token:document.getElementById('saved-token').checked};
      if (request.body) payload.body = typeof request.body === 'string' ? JSON.parse(request.body) : request.body;
      request.url = location.origin+'/api/manual-request'; request.method='POST';
      request.headers = {'Content-Type':'application/json', 'X-Control-Token':controlToken};
      request.body=JSON.stringify(payload); return request;
    }
  });
}).catch(error=>{document.getElementById('swagger-error').textContent=error.message;});
