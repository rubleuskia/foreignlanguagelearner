import io
import json
import time
import unittest
from types import SimpleNamespace as NS
from unittest.mock import Mock, patch
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives import serialization
import jwt
from backend.cloud.apple_identity import AppleConsent
from backend.cloud.errors import CloudError
from backend.cloud.identity import Identity
from backend.translation import test_translation as fixture
from backend.billing import api


class AppleConsentTests(unittest.TestCase):
    def setUp(self):
        self.identity_key = rsa.generate_private_key(public_exponent=65537,key_size=2048)
        self.signing_key = ec.generate_private_key(ec.SECP256R1())
        pem = self.signing_key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
        self.subject='apple-user'
        self.jwks=Mock(); self.jwks.get_signing_key_from_jwt.return_value=NS(key=self.identity_key.public_key())
        self.calls=[]
        self.consent=AppleConsent('app','team','kid',pem,self.open,self.jwks)

    def open(self,request,timeout):
        self.calls.append(request)
        if request.full_url.endswith('/revoke'): return io.BytesIO(b'')
        now=int(time.time())
        token=jwt.encode({'iss':'https://appleid.apple.com','aud':'app','sub':self.subject,'iat':now,'exp':now+300},self.identity_key,algorithm='RS256')
        return io.BytesIO(json.dumps({'id_token':token,'refresh_token':'test-refresh'}).encode())

    def test_verified_same_apple_subject_is_revoked_without_storing_tokens(self):
        prepared=self.consent.prepare('fresh-code','apple-user')
        self.assertEqual('refresh_token',prepared['token_type_hint'])
        self.consent.revoke(prepared)
        self.assertTrue(self.calls[-1].full_url.endswith('/revoke'))
        self.assertEqual(2,len(self.calls))

    def test_foreign_apple_account_and_missing_binding_cannot_revoke(self):
        for expected in ['other-user',None]:
            with self.assertRaises(CloudError): self.consent.prepare('code',expected)
        self.assertEqual(1,len(self.calls))


class AccountDeletionTests(unittest.TestCase):
    def setUp(self):
        self.force_moto = True
        fixture.TranslationTests.setUp(self)

    def invoke(self,consent):
        import boto3
        secret=boto3.client('secretsmanager',region_name='eu-central-1').create_secret(Name='apple-delete',SecretString='{"private_key":"test"}')['ARN']
        identity=Mock(); identity.authenticate.return_value=Identity('alice','apple_alice','apple-subject')
        identity.cognito.exceptions=NS(UserNotFoundException=type('Missing',(Exception,),{}))
        env={'AWS_DEFAULT_REGION':'eu-central-1','APPLE_SIGNIN_SECRET_ARN':secret,'APPLE_NATIVE_CLIENT_ID':'app',
            'APPLE_TEAM_ID':'team','APPLE_SIGNIN_KEY_ID':'kid','USER_POOL_ID':'pool'}
        with patch.object(api.runtime,'identity',return_value=identity),patch.object(api.runtime,'repository',return_value=self.billing),\
             patch('backend.cloud.apple_identity.AppleConsent',return_value=consent),patch.dict('os.environ',env):
            response=api.deletion_handler({'body':'{"authorization_code":"fresh-code"}'},None)
        return response,identity

    def test_revoke_failure_still_deletes_cloud_data_and_requires_manual_revocation(self):
        consent=Mock(); consent.revoke.side_effect=TimeoutError('secret-refresh-token')
        response,identity=self.invoke(consent)
        self.assertEqual(200,response['statusCode']); self.assertNotIn('secret-refresh',response['body'])
        self.assertEqual('manual_required',json.loads(response['body'])['apple_revocation'])
        self.assertEqual('deleted',self.billing.account('alice')['state'])
        identity.cognito.admin_delete_user.assert_called_once()

    def test_explicit_manual_deletion_does_not_require_apple_token_or_secret(self):
        identity=Mock(); identity.authenticate.return_value=Identity('alice','apple_alice')
        identity.cognito.exceptions=NS(UserNotFoundException=type('Missing',(Exception,),{}))
        with patch.object(api.runtime,'identity',return_value=identity),patch.object(api.runtime,'repository',return_value=self.billing),patch.dict('os.environ',{'USER_POOL_ID':'pool'}):
            result=api.deletion_handler({'body':'{"manual_revocation":true}'},None)
        self.assertEqual(200,result['statusCode']); self.assertEqual('manual_required',json.loads(result['body'])['apple_revocation'])
        self.assertEqual('deleted',self.billing.account('alice')['state'])

    def test_foreign_proof_does_not_delete_account(self):
        consent=Mock(); consent.prepare.side_effect=CloudError('APPLE_ACCOUNT_CONFLICT',409)
        response,identity=self.invoke(consent)
        self.assertEqual(409,response['statusCode']); self.assertEqual('active',self.billing.account('alice')['state'])
        identity.cognito.admin_delete_user.assert_not_called()

    def test_tombstone_precedes_revocation_and_subscription_is_not_cancelled(self):
        consent=Mock()
        consent.revoke.side_effect=lambda _:self.assertEqual('deleted',self.billing.account('alice')['state'])
        response,identity=self.invoke(consent)
        self.assertEqual(200,response['statusCode']); self.assertFalse(json.loads(response['body'])['subscription_cancelled'])
        identity.cognito.admin_delete_user.assert_called_once()


class IdentityEventTests(unittest.TestCase):
    def setUp(self):
        self.force_moto=True; fixture.TranslationTests.setUp(self)
        self.key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        self.jwks=Mock(); self.jwks.get_signing_key_from_jwt.return_value=NS(key=self.key.public_key())
        self.now=int(time.time()); self.subject='apple-bound-subject'
        self.billing.bind_identity(Identity('alice','apple_alice',self.subject,self.now-100))

    def event(self,kind='consent-revoked',when=None,audience='app'):
        from uuid import uuid4
        from backend.cloud.apple_identity_events import verified_event
        value={'iss':'https://appleid.apple.com','aud':audience,'iat':self.now,'jti':str(uuid4()),
            'events':{'type':kind,'sub':self.subject,'event_time':when or self.now-50,'email':'never-retain@example.invalid'}}
        signed=jwt.encode(value,self.key,algorithm='RS256')
        return verified_event(signed,['app'],self.jwks)

    def process(self,event):
        from backend.billing.service import BillingService
        event_id,fields=event
        self.billing.record_identity_event(event_id,fields,self.now)
        deletion=Mock()
        BillingService(self.billing,None,clock=lambda:self.now,delete_identity=deletion).process_event(event_id)
        return deletion

    def test_consent_revocation_requires_fresh_signin_and_preserves_account_token(self):
        before=self.billing.account('alice')['app_account_token']
        self.process(self.event())
        account=self.billing.account('alice')
        self.assertEqual('revoked',account['state']); self.assertEqual(self.now-50,account['valid_after'])
        with self.assertRaises(CloudError): self.billing.bind_identity(Identity('alice','apple_alice',self.subject,self.now-100))
        restored=self.billing.bind_identity(Identity('alice','apple_alice',self.subject,self.now))
        self.assertEqual('active',restored['state']); self.assertEqual(before,restored['app_account_token'])
        self.process(self.event(when=self.now-60))
        self.assertEqual('active',self.billing.account('alice')['state'])

    def test_permanent_apple_deletion_is_not_undone_by_newer_login_or_old_event_order(self):
        self.process(self.event())
        self.billing.bind_identity(Identity('alice','apple_alice',self.subject,self.now))
        deletion=self.process(self.event(kind='account-deleted',when=self.now-70))
        deletion.assert_called_once_with('apple_alice')
        self.assertEqual('deleted',self.billing.account('alice')['state'])
        with self.assertRaises(CloudError): self.billing.bind_identity(Identity('alice','apple_alice',self.subject,self.now+1))

    def test_wrong_audience_forgery_and_email_fields_are_not_accepted_or_stored(self):
        with self.assertRaises(CloudError): self.event(audience='foreign-app')
        event_id,fields=self.event(kind='email-disabled')
        self.assertNotIn('email',fields)
        self.process((event_id,fields))
        record=self.billing.event(event_id)
        self.assertNotIn('payload',record); self.assertNotIn('email',record)
        self.assertEqual('active',self.billing.account('alice')['state'])

    def test_session_floor_rejects_old_jwt_after_account_reactivation(self):
        from backend.cloud.identity import IdentityService
        self.process(self.event()); self.billing.bind_identity(Identity('alice','apple_alice',self.subject,self.now))
        cognito=Mock(); cognito.get_user.return_value={'Username':'apple_alice','UserAttributes':[{'Name':'sub','Value':'alice'}]}
        service=IdentityService(cognito,'issuer','client','access',account_lookup=lambda _:self.billing.account('alice'))
        claims={'iss':'issuer','client_id':'client','token_use':'access','sub':'alice','scope':'access','auth_time':str(self.now-100)}
        event={'headers':{'authorization':'Bearer token'},'requestContext':{'authorizer':{'jwt':{'claims':claims}}}}
        with self.assertRaises(CloudError) as error: service.authenticate(event)
        self.assertEqual('SESSION_REVOKED',error.exception.code)
        claims['auth_time']=str(self.now)
        self.assertEqual('alice',service.authenticate(event).user_id)
