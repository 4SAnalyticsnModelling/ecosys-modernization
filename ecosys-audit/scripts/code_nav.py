"""Read-only batch code navigation: symbols, search and bounded source ranges."""
from __future__ import annotations
import argparse
import ast
import contextlib
import hashlib
import io
import json
from pathlib import Path
import re
from workflow import ROOT, ProtocolError, inside

MAX_LINES=200
MAX_CHARS=12000
DECL=re.compile(r'^\s*(?:(?:pub|export|extern|inline|noinline|async|static|public|private|protected)\s+)*(?:fn\s+([\w]+)|(?:const|var)\s+([\w]+)\s*=|(?:class|struct|enum|interface|function)\s+([\w]+))')


class Reader:
    def __init__(self,root=ROOT):
        self.root=root;self.files={};self.f77=None
    def source(self,name):
        p=inside(self.root,name)
        if not p.is_file():raise ProtocolError('not a file: '+name)
        if name not in self.files:
            data=p.read_bytes()
            if len(data)>8*1024*1024:raise ProtocolError('source exceeds 8 MiB; use rg or a narrower artifact')
            self.files[name]=(data.decode('latin-1' if p.suffix.lower() in ['.f','.h'] and name.startswith('f77src/') else 'utf-8',errors='replace').splitlines(),hashlib.sha256(data).hexdigest())
        return self.files[name]
    def query(self,q):
        name=q['path'];lines,sha=self.source(name);op=q['op'];limit=min(max(int(q.get('limit',60)),1),MAX_LINES)
        if name.startswith('f77src/'):
            import f77query
            if self.f77 is None:self.f77=f77query.load(self.root/'audit/manifest/f77index.json')
            unit=f77query.resolve_unit(self.f77,name)
            entry=next(x for x in self.f77['files'] if x['path']==unit['file'])
            if not entry.get('in_build') and not q.get('include_unbuilt',False):
                raise ProtocolError('not in legacy build; set include_unbuilt only for explicit dormant-scope audit')
            if str(entry.get('sha256','')).lower()!=sha.lower():raise ProtocolError('stale Fortran index; rebuild before reading')
        rows=[]
        if op=='show':
            start=int(q.get('start',1));end=int(q.get('end',start+limit-1))
            if start<1 or end<start:raise ProtocolError('invalid source range')
            rows=[{'line':n,'text':lines[n-1]} for n in range(start,min(end,len(lines))+1)]
        elif op=='search':
            pattern=q['pattern'];literal=q.get('literal',True)
            regex=None if literal else re.compile(pattern)
            rows=[{'line':i,'text':line} for i,line in enumerate(lines,1)
                  if (pattern in line if literal else bool(regex.search(line)))]
        elif op=='imports':
            rows=[{'line':i,'text':line.strip()} for i,line in enumerate(lines,1)
                  if re.search(r'@import\(|^\s*(?:from |import |#include|include |use |require\()',line,re.I)]
        elif op=='outline':
            if name.startswith('f77src/'):
                # Use indexed loops/prose, not a generic language regex.
                rows=[{'line':unit['line_start'],'text':unit['kind']+' '+unit['name']}]
                rows += [{'line':x.get('line_start',x.get('start',0)), 'text':json.dumps(x)}
                         for x in unit['loops'] if x.get('depth',0)<=int(q.get('depth',1))]
                rows += [{'line':x['line_start'],'end':x['line_end'],'text':x['text']}
                         for x in unit['sections'] if x['kind']=='prose' or q.get('all_sections',False)]
                rows.sort(key=lambda x:x['line'])
            elif name.endswith('.py'):
                tree=ast.parse('\n'.join(lines))
                rows=[{'line':x.lineno,'end':x.end_lineno,'text':type(x).__name__+' '+x.name}
                      for x in ast.walk(tree) if isinstance(x,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef))]
                rows.sort(key=lambda x:x['line'])
            else:
                rows=[{'line':i,'text':line.strip()} for i,line in enumerate(lines,1)
                      if DECL.match(line) and len(line)-len(line.lstrip())<=4*int(q.get('depth',1))
                      and (not name.endswith('.zig') or re.search(r'\bfn\s|=\s*(?:packed\s+|extern\s+)?(?:struct|enum|union|opaque)\b',line)
                           or q.get('constants',False))]
        else:raise ProtocolError('op must be outline, imports, search or show')
        total=len(rows);selected=[];chars=0
        for row in rows[:limit]:
            if chars+len(row['text'])>MAX_CHARS:break
            selected.append(row);chars+=len(row['text'])
        return {'path':name,'sha256':sha,'op':op,'total_matches':total,'rows':selected,
                'truncated':len(selected)<total,'limitations':'Lexical outline except Python AST/Fortran index; no semantic equivalence or complete call graph proof.'}


def batch(root,requests):
    if not isinstance(requests,list) or not 1<=len(requests)<=24:raise ProtocolError('provide 1..24 requests')
    reader=Reader(root);out=[];remaining=24000
    for q in requests:
        try:
            result=reader.query(q)
            while result.get("rows") and len(json.dumps(result))>remaining:
                result["rows"].pop();result["truncated"]=True
            remaining=max(0,remaining-len(json.dumps(result)))
            out.append(result)
        except Exception as e:
            out.append({'request':q,'error':str(e)})
    return out


def main():
    p=argparse.ArgumentParser(description=__doc__);g=p.add_mutually_exclusive_group(required=True)
    g.add_argument('--requests',help='repository-local JSON array file');g.add_argument('--json',help='JSON array')
    a=p.parse_args();requests=json.loads(inside(ROOT,a.requests).read_text() if a.requests else a.json)
    result=batch(ROOT,requests);print(json.dumps(result,ensure_ascii=True))
    return 1 if any('error' in x for x in result) else 0
if __name__=='__main__':raise SystemExit(main())
