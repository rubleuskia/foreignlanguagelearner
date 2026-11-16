"""Read-only compatibility checks for digest-pinned alignment worker images."""
import hashlib
import json
import re
from urllib.parse import urlsplit
from urllib.request import build_opener, HTTPRedirectHandler
from .config import ControlError

CONTRACT_LABEL = 'io.fll.worker.contracts'
BOOK_CONTRACT = 'book-queue-v1'
REVISION_LABEL = 'org.opencontainers.image.revision'
CONFIG_LIMIT = 262144
DIGEST = re.compile(r'sha256:[a-f0-9]{64}')
INDEX_TYPES = {'application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json'}
MANIFEST_TYPES = {'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def download_config(url, region):
    parsed = urlsplit(url)
    host = parsed.hostname or ''
    allowed = {f's3.{region}.amazonaws.com', f's3-{region}.amazonaws.com'}
    if (parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in {None, 443}
            or parsed.fragment or not any(host == suffix or host.endswith('.' + suffix) for suffix in allowed)):
        raise ControlError('ECR вернул неподдерживаемый адрес конфигурации образа.')
    with build_opener(NoRedirect()).open(url, timeout=10) as response:
        raw = response.read(CONFIG_LIMIT + 1)
    if len(raw) > CONFIG_LIMIT: raise ControlError('Конфигурация образа превышает допустимый размер.')
    return raw


def manifest(client, registry, repository, image_digest):
    if not isinstance(image_digest, str) or not DIGEST.fullmatch(image_digest):
        raise ControlError('Некорректный digest образа.')
    result = client.batch_get_image(registryId=registry, repositoryName=repository,
                                    imageIds=[{'imageDigest': image_digest}])
    images = result.get('images', [])
    if result.get('failures') or len(images) != 1 or images[0].get('imageId', {}).get('imageDigest') != image_digest:
        raise ControlError('Не удалось прочитать закреплённый образ в ECR.')
    return json.loads(images[0]['imageManifest'])


def inspect(client, registry, region, repository, image_digest, *, download=download_config):
    selected = manifest(client, registry, repository, image_digest)
    if selected.get('mediaType') in INDEX_TYPES:
        candidates = [item for item in selected.get('manifests', [])
            if item.get('platform', {}).get('os') == 'linux' and item.get('platform', {}).get('architecture') == 'amd64']
        if len(candidates) != 1: raise ControlError('Образ должен содержать одну платформу Linux amd64.')
        selected = manifest(client, registry, repository, candidates[0].get('digest'))
    if selected.get('schemaVersion') != 2 or selected.get('mediaType') not in MANIFEST_TYPES:
        raise ControlError('Неподдерживаемый формат worker image. Пересоберите образ штатным скриптом.')
    descriptor = selected.get('config', {})
    config_digest, size = descriptor.get('digest'), descriptor.get('size')
    if (not isinstance(config_digest, str) or not DIGEST.fullmatch(config_digest)
            or type(size) is not int or not 0 < size <= CONFIG_LIMIT):
        raise ControlError('Некорректная конфигурация worker image.')
    link = client.get_download_url_for_layer(registryId=registry, repositoryName=repository, layerDigest=config_digest)
    if link.get('layerDigest') != config_digest: raise ControlError('Digest конфигурации образа не совпадает.')
    raw = download(link['downloadUrl'], region)
    if len(raw) != size or 'sha256:' + hashlib.sha256(raw).hexdigest() != config_digest:
        raise ControlError('Контрольная сумма конфигурации образа не совпадает.')
    config = json.loads(raw)
    labels = (config.get('config') or {}).get('Labels') or {}
    contracts = labels.get(CONTRACT_LABEL, '').split(',')
    revision = labels.get(REVISION_LABEL, '')
    if (config.get('os') != 'linux' or config.get('architecture') != 'amd64'
            or (config.get('config') or {}).get('Entrypoint') != ['python', 'tools/subtitle-aligner/worker/worker.py']
            or BOOK_CONTRACT not in contracts or 'catalog-chapters-v1' not in contracts or not re.fullmatch(r'[a-f0-9]{40}', revision)):
        raise ControlError('Выбранный образ не подтверждает поддержку книжной очереди (book-queue-v1) и каталога (catalog-chapters-v1). '
            'Соберите и опубликуйте новый образ через scripts/alignment-image.py, затем укажите его digest '
            'и новые замеры. Старый образ пилота запускать в книжном сервисе нельзя.')
    return {'digest': image_digest, 'contracts': contracts, 'source_revision': revision, 'platform': 'linux/amd64'}
