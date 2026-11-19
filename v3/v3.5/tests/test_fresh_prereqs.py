#!/usr/bin/env python3
"""Exercise fresh bootstrap using a simulated API; no cluster changes."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
p=os.environ['MOCK_STATE']
s=json.load(open(p))
a=sys.argv[1:]
a=[x for x in a if not x.startswith('--request-timeout=')]
ns=None
if '-n' in a:
 i=a.index('-n'); ns=a[i+1]; del a[i:i+2]
def out(x): print(json.dumps(x))
def save(): json.dump(s,open(p,'w'))
if a == ['whoami']: print('admin'); sys.exit()
if a[:3] == ['get','clusterversion','version']: print('5.0.1'); sys.exit()
if a[:2] == ['get','crd']:
 if '-o' in a and 'name' in a: print('crd/'+a[2])
 sys.exit()
if a[:2] == ['get','namespace']: sys.exit()
if a[:2] == ['get','operatorgroups.operators.coreos.com']:
 out({'items':[{'spec':s.get('group',{})}]}); sys.exit()
if a[:2] == ['get','subscriptions.operators.coreos.com']: out({'items':s['subs']}); sys.exit()
if a[:2] == ['get','csv'] and '-A' in a:
 for sub in s['subs']: print(sub['status']['installedCSV'], 'Succeeded')
 for c in s.get('orphan_csvs',[]): print(c, 'Failed')
 sys.exit()
if a[:2] == ['get','subscription']:
 matches=[x for x in s['subs'] if x['metadata']['name']==a[2] and x['metadata']['namespace']==ns]
 if not matches: sys.exit(1)
 out(matches[0]);sys.exit()
if a[:2] == ['get','csv']: print('Succeeded');sys.exit()
if a[:2] == ['get','packagemanifests.packages.operators.coreos.com']:
 pkg=a[2]; csv=s['catalog'][pkg]; ch='stable-3.5' if pkg=='servicemeshoperator3' else 'stable'
 out({'status':{'catalogSource':'redhat-operators','catalogSourceNamespace':'openshift-marketplace','channels':[{'name':ch,'currentCSV':csv}]}});sys.exit()
if a[:3] == ['create','-f','-']:
 obj=json.load(sys.stdin); pkg=obj['spec']['name']; obj['status']={'installedCSV':s['catalog'][pkg]}; s['subs'].append(obj); s['creates']+=1; save();sys.exit()
if a[:2] == ['get','storageclass']:
 if '-o' not in a: sys.exit(0 if a[2] in ['gp3-csi',s['volume_class']] else 1)
 out({'provisioner':'openshift-storage.noobaa.io/obc','parameters':{'bucketclass':s.get('bucket_class','noobaa-default-bucket-class')}});sys.exit()
if a[:2] == ['get','noobaas.noobaa.io']:
 if len(a)>2 and a[2]=='noobaa': out({'status':{'phase':s.get('phase','Ready')}})
 else: out({'items':[{'metadata':{'name':'noobaa'}}]})
 sys.exit()
if a[:2] == ['get','backingstores.noobaa.io']:
 out({'status':{'phase':'Ready'},'spec':{'type':'pv-pool','pvPool':{'storageClass':s['volume_class'],'numVolumes':3}}});sys.exit()
if a[:2] == ['get','bucketclasses.noobaa.io']:
 out({'status':{'phase':'Ready'},'spec':{'placementPolicy':{'tiers':[{'backingStores':[s.get('backing_store','noobaa-default-backing-store')]}]}}});sys.exit()
if a[:2] == ['get','pvc']:
 out({'items':[{'metadata':{'name':'noobaa-default-backing-store-'+str(i)},'spec':{'storageClassName':s['volume_class'],'volumeName':'pv'+str(i)},'status':{'phase':('Pending' if s.get('unbound') and i==0 else 'Bound')}} for i in range(3)]});sys.exit()
if a[:2] == ['get','storageclusters.ocs.openshift.io']:
 out({'items':[{'metadata':{'name':'ocs-external-storagecluster'},'spec':{}}]});sys.exit()
print('unexpected oc:',a,file=sys.stderr);sys.exit(9)
'''

class TestFreshPrereqs(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
  self.path=pathlib.Path(self.tmp.name); mock=self.path/'oc'; mock.write_text(MOCK); mock.chmod(0o755)
  self.state={'subs':[], 'creates':0, 'volume_class':'ocs-external-storagecluster-ceph-rbd', 'catalog':{
   'servicemeshoperator3':'servicemeshoperator3.v3.5.0','kiali-ossm':'kiali-operator.v2.33.1',
   'opentelemetry-product':'opentelemetry-operator.v0.158.0-1','tempo-product':'tempo-operator.v0.22.0-5',
   'cluster-observability-operator':'cluster-observability-operator.v1.5.5'}}
  self.env=os.environ.copy();self.env.update(PATH=str(self.path)+':'+self.env['PATH'],MOCK_STATE=str(self.path/'state.json'))
 def run_script(self, script, *args):
  (self.path/'state.json').write_text(json.dumps(self.state))
  p=subprocess.run([str(ROOT/script),*args],env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
  self.state=json.loads((self.path/'state.json').read_text());return p
 def test_install_is_idempotent_and_keeps_existing_subscription(self):
  existing={'metadata':{'name':'existing-tempo','namespace':'openshift-operators'},'spec':{'name':'tempo-product','channel':'custom'},'status':{'installedCSV':self.state['catalog']['tempo-product']}}
  self.state['subs']=[existing]
  p=self.run_script('scripts/bootstrap-operators.sh','--apply');self.assertEqual(p.returncode,0,p.stdout+p.stderr)
  self.assertEqual(self.state['creates'],4);self.assertEqual(self.state['subs'][0],existing)
  p=self.run_script('scripts/bootstrap-operators.sh','--apply');self.assertEqual(p.returncode,0,p.stdout+p.stderr);self.assertEqual(self.state['creates'],4)
 def test_restricted_group_and_orphan_csv_refuse_changes(self):
  self.state['group']={'targetNamespaces':['example']};p=self.run_script('scripts/bootstrap-operators.sh','--apply');self.assertNotEqual(p.returncode,0);self.assertEqual(self.state['creates'],0)
  self.state.pop('group');self.state['orphan_csvs']=['servicemeshoperator3.v3.4.0'];p=self.run_script('scripts/bootstrap-operators.sh','--apply');self.assertNotEqual(p.returncode,0);self.assertEqual(self.state['creates'],0)
 def test_unexpected_catalog_version_refuses_install(self):
  self.state['catalog']['servicemeshoperator3']='servicemeshoperator3.v3.6.0';p=self.run_script('scripts/bootstrap-operators.sh','--apply');self.assertNotEqual(p.returncode,0);self.assertEqual(self.state['creates'],0)
 def test_external_and_aws_pv_storage(self):
  for cls in ('ocs-external-storagecluster-ceph-rbd','gp3-csi'):
   self.state['volume_class']=cls;p=self.run_script('storage/odf/check-mcg.sh','--quick');self.assertEqual(p.returncode,0,p.stdout+p.stderr)
 def test_unhealthy_storage_rejected(self):
  for key,value in [('unbound',True),('backing_store','foreign-store'),('bucket_class','foreign-class')]:
   self.state[key]=value;p=self.run_script('storage/odf/check-mcg.sh','--quick');self.assertNotEqual(p.returncode,0,key);del self.state[key]
 def test_bootstrap_preserves_external_odf_even_when_unhealthy(self):
  p=self.run_script('storage/odf/bootstrap-mcg.sh');self.assertEqual(p.returncode,0,p.stdout+p.stderr)
  self.state['unbound']=True;p=self.run_script('storage/odf/bootstrap-mcg.sh');self.assertNotEqual(p.returncode,0);self.assertIn('refusing changes',p.stderr)

if __name__=='__main__': unittest.main()
