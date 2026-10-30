#!/usr/bin/env python3
# Helper that runs the native RDD (receipt-driven development) review flow of `gentle-ai` on the HEAD commit of a
# worktree, so an orchestrator can do it in one command instead of pasting the provider-issued steps by hand.
# It is not used by bridge.sh or the tests; run it manually.
#   rdd.py preflight <worktree> <base-ref>   print risk level, changed files/lines and risk evidence
#   rdd.py grant     <worktree> <base-ref>   grant consent, run the lens captures, acknowledge the approved result
# Needs `gentle-ai` on PATH. Exits 1 when a capture or transition is not the expected one.
import sys,json,subprocess
from concurrent.futures import ThreadPoolExecutor
# usage: rdd.py preflight|grant <worktree> <base-ref>   (candidate = HEAD of the worktree, committed-only)
mode,wt,base=sys.argv[1:4]
def run(c):
    r=subprocess.run(c,shell=True,cwd=wt,capture_output=True,text=True);return r.stdout+r.stderr
st=json.loads(run(f"gentle-ai review status --cwd . --contract gentle-ai.review-integration/v2 --agent claude-code --next-transition --base-ref {base} --committed-only"))
c=json.loads(run(st['next_transition']['execute']['command']))
if mode=='preflight':
    print(c.get('risk_level'),c.get('changed_files'),c.get('changed_lines'),c.get('risk_evidence'));sys.exit()
g=[x for x in c['choices'] if x['answer']=='granted'][0]['invocation']
s=json.loads(run(g)); print(s.get('action'),s.get('state'))
re=s['next_transition']['execute']['command']
for _ in range(6):
    t=json.loads(run(re))['next_transition']
    if t['kind']=='collect':
        cmds=['gentle-ai review capture-result '+' '.join(a['token'] for a in i['arguments']) for i in t['collect']['inputs']]
        with ThreadPoolExecutor(len(cmds)) as ex:
            for o in ex.map(run,cmds):
                try: print('capture:',json.loads(o).get('state'))
                except Exception: print('capture raw:',o[:800]); sys.exit(1)
    elif t['kind']=='execute' and 'acknowledge' in t['execute']['command']:
        print(run(t['execute']['command'])[:450].replace('\n',' ')); sys.exit()
    else:
        print(json.dumps(t)[:900]); sys.exit(1)
