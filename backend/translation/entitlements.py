"""Public allowance projection; only transactional admission can reserve usage."""
from backend.cloud.dynamo import encode, decode
from backend.cloud.errors import CloudError
from .policy import period


def augment(view, account, subscriptions, policy, client, table, now):
    period_id, reset = period(now)
    allowance = {}
    for feature in ['translations', 'alignments']:
        try: _, limit = policy.access(account, subscriptions, now, feature)
        except CloudError: limit = 0
        key = f"quota:{account['user_id']}:{feature}:{period_id}"
        row = decode(client.get_item(TableName=table, Key=encode({'counter_id': key}), ConsistentRead=True).get('Item'))
        used = (row or {}).get('value', 0)
        allowance[feature] = {'limit': limit, 'used': used, 'remaining': max(0, limit - used), 'reset_at': reset}
    view.update(policy_version=policy.version, allowance=allowance)
    translations = policy.enabled and allowance['translations']['remaining'] > 0
    view['features'] = {'context_analysis': translations, 'word_explanation': translations,
        'alignment': policy.alignment_enabled and allowance['alignments']['remaining'] > 0}
    return view
