#!/usr/bin/env python3
"""Generate public iOS cloud configuration from CDK outputs, without deploying anything."""
import argparse
import json
from pathlib import Path
import plistlib
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--outputs', type=Path, required=True)
    parser.add_argument('--stage', choices=['dev', 'prod'], required=True)
    parser.add_argument('--products', nargs='+', required=True)
    for key in ['privacy', 'terms', 'support']: parser.add_argument('--'+key+'-url', required=True)
    parser.add_argument('--output', type=Path, default=Path('App/Configuration/CloudConfiguration.plist'))
    args = parser.parse_args()
    data = json.loads(args.outputs.read_text())[f'ForeignLanguageLearnerCloudFoundation-{args.stage}']
    config = {'CloudAPIBaseURL': data['ApiUrl'], 'CloudCognitoDomain': data['LoginUrl'], 'CloudClientID': data['ClientId'],
        'CloudCallbackURL':'fll://auth', 'CloudEnvironment':'Production' if args.stage == 'prod' else 'Sandbox',
        'CloudProducts':args.products, 'CloudPrivacyURL':args.privacy_url, 'CloudTermsURL':args.terms_url, 'CloudSupportURL':args.support_url}
    for key, value in config.items():
        if key.endswith('URL') and key != 'CloudCallbackURL' or key == 'CloudCognitoDomain':
            parsed = urlparse(value)
            if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
                parser.error('All service and policy URLs must use HTTPS without credentials, query or fragment')
    if args.output.exists(): parser.error('Output already exists; review it before replacing environment configuration')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps(config, sort_keys=True))
    print(f'Wrote public {args.stage} app configuration to {args.output}. Regenerate the Xcode project before building.')


if __name__ == '__main__': main()
