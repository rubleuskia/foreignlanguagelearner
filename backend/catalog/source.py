"""Bounded, provider-pinned downloads. Never accept a client-supplied media URL."""
import html
import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request

from backend.cloud.errors import CloudError

API = 'https://wolnelektury.pl/api/'
MAX_TRACKS = 100  # Must match the iOS book importer, including chapter-preserving output.
PIPELINE = 'wl-chapters-v1'


def checked_url(url, media=False):
    p = urllib.parse.urlsplit(url)
    if (p.scheme != 'https' or p.netloc != 'wolnelektury.pl' or p.fragment
            or '%' in p.path or '..' in p.path or '\\' in p.path
            or not p.path.startswith('/media/book/' if media else '/api/')):
        raise CloudError('INVALID_SOURCE')
    if media and p.query:
        raise CloudError('INVALID_SOURCE')
    return url


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        checked_url(newurl, media=req.full_url.startswith('https://wolnelektury.pl/media/'))
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_url(url, *, media=False, method='GET'):
    request = urllib.request.Request(checked_url(url, media), method=method,
        headers={'User-Agent': 'ForeignLanguageLearner/1 (Wolne Lektury catalog)', 'Accept': 'application/json' if not media else '*/*'})
    try:
        return urllib.request.build_opener(Redirects()).open(request, timeout=15)
    except urllib.error.HTTPError as error:
        if error.code in {404, 410}:
            raise CloudError('SOURCE_UNAVAILABLE', 409) from None
        raise


def get_json(url):
    with open_url(url) as response:
        data = response.read(16_000_001)
    if len(data) > 16_000_000:
        raise CloudError('INVALID_SOURCE')
    return json.loads(data)


def identity(slug):
    if not re.fullmatch('[a-z0-9-]+', slug):
        raise CloudError('INVALID_SOURCE')
    return 'wl-' + slug[:96].rstrip('-') + '-' + hashlib.sha256(slug.encode()).hexdigest()[:8]


def shelves(genres):
    values = set()
    for genre in genres:
        g = genre.lower()
        if 'kryminal' in g: values.add('crime')
        if 'przygod' in g or g == 'epos': values.add('adventure')
        if g in {'baśń', 'bajka', 'bajka ludowa', 'legenda'} or 'dzieci' in g: values.add('fairy-tales')
        if 'powieść' in g or g == 'romans': values.add('novels')
        if g in {'opowiadanie', 'nowela', 'przypowieść'}: values.add('short-stories')
        if any(s in g for s in ['dramat', 'tragedia', 'komedia', 'tragifarsa']): values.add('drama')
        if any(s in g for s in ['wiersz', 'poemat', 'sonet', 'pieśń', 'fraszka', 'tren', 'hymn', 'ballada', 'oda', 'sielanka', 'epigramat', 'anakreontyk', 'plankt']): values.add('poetry')
        if any(s in g for s in ['esej', 'rozprawa', 'traktat', 'pamiętnik', 'reportaż', 'list', 'kazanie', 'akt prawny']): values.add('essays')
    return sorted(values or {'other'})


def normalize(slug, detail, *, validators=None):
    if detail.get('language') != 'pol' or detail.get('preview'):
        return None
    tracks = [dict(url=checked_url(m['url'], True), title=m.get('name') or str(i + 1),
                   artist=m.get('artist', ''), director=m.get('director', ''))
              for i, m in enumerate(detail.get('media', [])) if m.get('type') == 'mp3']
    text = detail.get('txt') or detail.get('epub')
    if not tracks or not text:
        return None
    checked_url(text, True)
    parent = detail.get('parent')
    genres = [g['name'] for g in detail.get('genres', [])]
    source = {'slug': slug, 'text': text, 'textFormat': 'txt' if detail.get('txt') else 'epub',
              'tracks': tracks, 'validators': validators or []}
    version = hashlib.sha256(json.dumps(source, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return {'id': identity(slug), 'title': detail['title'], 'language': 'pl',
        'author': ', '.join(a['name'] for a in detail.get('authors', [])),
        'genres': genres, 'shelves': shelves(genres), 'coverURL': detail.get('simple_cover') or detail.get('cover'),
        'duration': detail.get('audio_length', ''), 'chapterCount': len(tracks),
        'parentID': identity(parent['slug']) if parent else None,
        'parentTitle': parent.get('title') if parent else None, 'sourceURL': detail['url'],
        'sourceVersion': version, 'excerpt': html.unescape(re.sub('<[^>]*>', '', (detail.get('fragment_data') or {}).get('html', '')))[:2000], 'source': source}


def validators(source):
    result = []
    for url in [source['text']] + [t['url'] for t in source['tracks']]:
        with open_url(url, media=True, method='HEAD') as response:
            result.append({'url': url, 'etag': response.headers.get('ETag', ''),
                'modified': response.headers.get('Last-Modified', ''),
                'bytes': int(response.headers.get('Content-Length', 0))})
    return result


def download(url, path, remaining, expected=None):
    count = 0
    digest = hashlib.sha256()
    with open_url(url, media=True) as response, path.open('xb') as output:
        if expected and ((expected.get('etag') and response.headers.get('ETag') != expected['etag'])
                or (expected.get('modified') and response.headers.get('Last-Modified') != expected['modified'])):
            raise CloudError('SOURCE_CHANGED', 409)
        declared = int(response.headers.get('Content-Length', 0))
        if declared > remaining:
            raise CloudError('INPUT_TOO_LARGE', 413)
        while block := response.read(min(1024 * 1024, remaining - count + 1)):
            count += len(block)
            if count > remaining:
                raise CloudError('INPUT_TOO_LARGE', 413)
            output.write(block); digest.update(block)
    if count == 0 or (declared and declared != count):
        raise CloudError('SOURCE_UNAVAILABLE', 409)
    return count, digest.hexdigest()
