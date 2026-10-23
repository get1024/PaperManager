#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/.build"
# /tmp and /var are symlink aliases on macOS; exercise the no-symlink copy
# policy from an ordinary physical workspace directory.
TASK_WORK_DIR=$(mktemp -d "$TASK_ROOT/.build/lattice-archive-tests.XXXXXX")
trap 'rm -rf "$TASK_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
python3 - "$TASK_WORK_DIR" <<'PY'
import sys,json,zipfile,copy,struct,warnings
from pathlib import Path
root=Path(sys.argv[1]); pid='00000000-0000-0000-0000-000000000001'
data={'papers':[{'id':pid,'title':'Fixture','authors':['Einstein, Albert'],'editors':[],'translators':[],
 'bibtexKey':'OriginalSourceKey','paperType':'preprint','year':2026,'dateAdded':'2026-07-29T06:21:23Z',
 'rating':4,'notes':'fixture note','abstract':'fixture abstract','eprint':'2601.01234','hasPDF':False,
 'collectionIDs':[],'tagIDs':[],'extraFields':{'fixtureExtra':'kept'}}], 'collections':[], 'tags':[], 'templates':[],
 'annotations':[{'paperID':pid,'pageIndex':1,'pageLabel':'ii','type':'highlight','sortOrder':4,
 'boundsX':1.5,'boundsY':2.5,'boundsWidth':3.5,'boundsHeight':4.5,'text':'fixture selected text',
 'contents':'fixture annotation note','colorHex':'FFBABA'}]}
manifest={'version':1,'schemaVersion':2,'appVersion':'3.0','includesPDFs':False,
 'counts':{'papers':1,'collections':0,'tags':0,'templates':0,'annotations':1,'pdfs':0,'attachmentFiles':0}}
def archive(name,d=data,m=manifest,extra=None):
 with zipfile.ZipFile(root/(name+'.lattice'),'w',compression=zipfile.ZIP_DEFLATED) as z:
  z.writestr('manifest.json',json.dumps(m)); z.writestr('data.json',json.dumps(d))
  if extra:
   for member in extra if isinstance(extra,list) else [extra]: z.writestr(*member)
archive('valid'); d=copy.deepcopy(data);d['papers'][0]['dateAdded']='2026-07-29T06:21:23.123Z';archive('fractional',d)
d=copy.deepcopy(data);d['papers'][0]['hasPDF']=True;d['papers'][0]['pdfFilename']='Fixture original name.pdf';m=copy.deepcopy(manifest);m['counts']['pdfs']=1;m['includesPDFs']=True
archive('with-pdf',d,m,extra=('pdfs/'+pid+'.pdf',b'%PDF-1.4\nfixture payload\n%%EOF\n'))
with zipfile.ZipFile(root/'bad-json.lattice','w') as z:z.writestr('manifest.json',json.dumps(manifest));z.writestr('data.json','{')
d=copy.deepcopy(data);d['papers'].append(copy.deepcopy(d['papers'][0]));m=copy.deepcopy(manifest);m['counts']['papers']=2;archive('duplicate-id',d,m)
d=copy.deepcopy(data);d['papers'][0]['collectionIDs']=[pid];archive('missing-reference',d)
m=copy.deepcopy(manifest);m['counts']['papers']=2;archive('bad-count',data,m)
d=copy.deepcopy(data);d['papers'][0]['rating']=True;archive('bad-type',d)
with warnings.catch_warnings():
 warnings.simplefilter('ignore');archive('duplicate-member',extra=('data.json',json.dumps(data)))
archive('traversal',extra=('../escaped.txt','should never extract'))
archive('oversized-json'); p=root/'oversized-json.lattice'; raw=bytearray(p.read_bytes()); pos=raw.index(b'PK\x01\x02');struct.pack_into('<I',raw,pos+24,2*1048576);p.write_bytes(raw)
archive('bad-local-header');p=root/'bad-local-header.lattice';raw=bytearray(p.read_bytes());raw[0]=0;p.write_bytes(raw)
aid='00000000-0000-0000-0000-000000000010'; aid2='00000000-0000-0000-0000-000000000011'
d=copy.deepcopy(data);d['papers'][0]['attachments']=[
 {'id':aid,'filename':'same name.txt','dateAdded':'2026-07-30T02:03:04.125Z','archivedRelativePath':'payloads/arbitrary-layout/one.bin'},
 {'id':aid2,'filename':'same name.txt','dateAdded':'2026-07-30T02:03:05Z','archivedRelativePath':'other-location/two.bin'}]
m=copy.deepcopy(manifest);m['counts']['attachmentFiles']=2
extras=[('payloads/arbitrary-layout/one.bin',b'first secondary payload\x00\xff'),('other-location/two.bin',b'second secondary payload')]
archive('with-attachments',d,m,extras)
meta=copy.deepcopy(d);meta['papers'][0]['attachments'][0]['archivedRelativePath']=None;meta['papers'][0]['attachments']=meta['papers'][0]['attachments'][:1]
archive('metadata-only-attachment',meta,manifest)
archive('missing-attachment',d,m,extras[:1])
bad=copy.deepcopy(d);bad['papers'][0]['attachments'][0]['archivedRelativePath']='../escape.txt';archive('attachment-traversal',bad,m,extras)
bad=copy.deepcopy(d);bad['papers'][0]['attachments'][0]['archivedRelativePath']='payloads/*';archive('attachment-wildcard',bad,m,extras)
bad=copy.deepcopy(d);bad['papers'][0]['attachments'][1]['id']=aid;archive('attachment-duplicate-id',bad,m,extras)
bad=copy.deepcopy(d);bad['papers'][0]['attachments'][1]['archivedRelativePath']=bad['papers'][0]['attachments'][0]['archivedRelativePath'];archive('attachment-duplicate-payload',bad,m,extras)
wrong=copy.deepcopy(m);wrong['counts']['attachmentFiles']=1;archive('attachment-bad-count',d,wrong,extras)
link=zipfile.ZipInfo('payloads/arbitrary-layout/one.bin');link.create_system=3;link.external_attr=(0o120777<<16)
archive('attachment-symlink',d,m,[(link,b'/private/never-follow'),extras[1]])
archive('attachment-corrupt-payload',d,m,extras);p=root/'attachment-corrupt-payload.lattice';raw=bytearray(p.read_bytes());pos=0
while True:
 pos=raw.find(b'PK\x03\x04',pos)
 if pos<0:break
 nl,el=struct.unpack_from('<HH',raw,pos+26);name=raw[pos+30:pos+30+nl].decode()
 if name=='payloads/arbitrary-layout/one.bin':raw[pos+30+nl+el]^=0x55;break
 pos+=30+nl+el
p.write_bytes(raw)
PY
mkdir "$TASK_WORK_DIR/Sources"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TASK_ROOT"/Sources/PaperManager/Services/*.swift \
    "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TASK_ROOT/Tests/LatticeArchiveTests.swift" "$TASK_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -swift-version 5 -sdk "$TEST_SDK" \
    "$TASK_WORK_DIR"/Sources/*.swift -o "$TASK_WORK_DIR/LatticeArchiveTests"
"$TASK_WORK_DIR/LatticeArchiveTests" "$TASK_WORK_DIR"
