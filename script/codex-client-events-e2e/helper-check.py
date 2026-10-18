import subprocess,json,time,uuid,tempfile,os,sys
helper=sys.argv[1]
with tempfile.NamedTemporaryFile() as sink:
 def invoke(**changes):
  p=dict(v=1,client_id=str(uuid.uuid4()),sequence=1,completed_turns=3,thread_epoch=2,session_id=str(uuid.uuid4()),input_ready=True,status='ready',captured_at=time.time()); p.update(changes)
  if p.get('completed_turns') == 'missing': del p['completed_turns']
  before=os.path.getsize(sink.name)
  r=subprocess.run([helper,'--codex-client-event'],input=json.dumps(p).encode(),env={**os.environ,'AWESOMUX_AGENT_EVENT_FILE':sink.name},capture_output=True)
  assert not r.stdout
  with open(sink.name,'rb') as f: f.seek(before); data=f.read()
  assert (r.returncode == 0) == bool(data), (r.returncode, data)
  return json.loads(data) if data else None
 e=invoke(); assert e and e['execution']=='waiting' and e['clientStatus']['pid']==os.getpid(),e
 assert e['clientStatus']['threadEpoch']==2
 assert e['clientStatus']['completedTurns']==3
 assert e['clientStatus']['startedAt']>0 and e['timestamp']==e['clientStatus']['capturedAt']
 assert invoke(status='working',input_ready=False)['execution']=='thinking'
 assert invoke(status='blocked',input_ready=False)['attentionReason']=='userInputRequired'
 failure=invoke(status='error',input_ready=False)
 assert failure and failure['execution']=='error' and 'attentionReason' not in failure
 assert 'execution' not in invoke(status='unavailable',input_ready=False,session_id=None)
 for changes in [dict(thread_epoch=0),dict(thread_epoch=None),dict(thread_epoch=-1),dict(completed_turns='missing'),dict(completed_turns=1.5),dict(completed_turns=None),dict(completed_turns=-1),dict(status='working'),dict(client_id='bad'),dict(sequence=0),dict(session_id='bad'),dict(captured_at=time.time()-20),dict(captured_at=time.time()+5),dict(v=2),dict(status='bad'),dict(client_id='x'*5000)]:
  assert invoke(**changes) is None,changes
 def open_document(thread_id):
  before=os.path.getsize(sink.name)
  r=subprocess.run([helper,'open-document','--provider','codex','/tmp/client-event.md'],env={**os.environ,'AWESOMUX_AGENT_EVENT_FILE':sink.name,'CODEX_THREAD_ID':thread_id},capture_output=True)
  assert not r.stdout
  with open(sink.name,'rb') as f: f.seek(before); return json.loads(f.read())
 thread_id=str(uuid.uuid4())
 document=open_document(thread_id)
 assert document.get('providerSessionID')==thread_id,document
 assert document['phase']=='open-document' and document['documentPath']=='/tmp/client-event.md'
 assert 'execution' not in document and 'clientStatus' not in document
 assert 'providerSessionID' not in open_document('invalid-thread-id')
 with tempfile.TemporaryDirectory() as missing_dir:
  payload=dict(v=1,client_id=str(uuid.uuid4()),sequence=1,completed_turns=0,thread_epoch=1,session_id=None,input_ready=False,status='unavailable',captured_at=time.time())
  result=subprocess.run([helper,'--codex-client-event'],input=json.dumps(payload).encode(),env={**os.environ,'AWESOMUX_AGENT_EVENT_FILE':os.path.join(missing_dir,'missing')},capture_output=True)
  assert result.returncode != 0 and not result.stdout and not result.stderr
print('PASS: mappings, process identity, producer timestamp and malformed/stale/oversized rejection')
