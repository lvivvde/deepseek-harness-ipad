#!/usr/bin/env python3
"""Linux/QEMU integration on a fresh temporary disk; prints fixed markers only."""
import argparse
import http.client
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time
import threading
import urllib.request
import uuid

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime',type=Path)
parser.add_argument('--scratch',type=Path,default=Path('/var/tmp'))
args=parser.parse_args()
stage='START'
token='0123456789abcdef0123456789abcdef'
headers={'X-Harness-Transfer':token}

def main():
 global stage
 with tempfile.TemporaryDirectory(prefix='harness-acceptance-',dir=args.scratch) as temporary:
  root=Path(temporary);disk=root/'user.raw'
  subprocess.run(['cp','--sparse=always',str(args.runtime/'user-seed.raw'),str(disk)],check=True)
  with disk.open('r+b') as stream:stream.truncate(8192*1024*1024)
  console,serial=socket.socketpair();control,qmp=socket.socketpair()
  command=['qemu-system-aarch64','-machine','virt','-cpu','cortex-a72','-smp','1','-m','2048','-accel','tcg','-nodefaults','-display','none','-monitor','none',
   '-chardev',f'socket,id=serial0,fd={serial.fileno()}','-serial','chardev:serial0',
   '-chardev',f'socket,id=control0,fd={qmp.fileno()}','-qmp','chardev:control0',
   '-netdev','user,id=net0,hostfwd=tcp:127.0.0.1:39080-:2999,hostfwd=tcp:127.0.0.1:39083-:3002,hostfwd=tcp:127.0.0.1:39084-:3003,hostfwd=tcp:127.0.0.1:39000-:40002',
   '-device','virtio-net-pci,netdev=net0,romfile=',
   '-kernel',str(args.runtime/'Image'),'-initrd',str(args.runtime/'initramfs.gz'),'-append',f'console=ttyAMA0 rdinit=/init harness.transfer={token}',
   '-drive',f'file={args.runtime}/system.raw,if=none,id=system,format=raw,readonly=on','-device','virtio-blk-pci,drive=system',
   '-drive',f'file={disk},if=none,id=user,format=raw','-device','virtio-blk-pci,drive=user']
  log=(root/'qemu.log').open('wb');process=subprocess.Popen(command,pass_fds=(serial.fileno(),qmp.fileno()),stdout=subprocess.DEVNULL,stderr=log)
  serial.close();qmp.close();console.settimeout(.2);control.settimeout(5)
  buffer=bytearray();qmpfile=control.makefile('rwb',buffering=0)
  stop_serial=threading.Event()
  def drain_serial():
   # The App always drains its serial channel. A blocked host HTTP request must
   # not backpressure QEMU's console while the guest grows ext4 or restarts.
   while not stop_serial.is_set():
    try:
     data=console.recv(65536)
     if not data:return
     buffer.extend(data)
    except socket.timeout:pass
    except OSError:return
  serial_reader=threading.Thread(target=drain_serial,daemon=True);serial_reader.start()
  def monitor(name,arguments={}):
   identifier=uuid.uuid4().hex
   qmpfile.write((json.dumps({'execute':name,'arguments':arguments,'id':identifier})+'\n').encode())
   while True:
    packet=json.loads(qmpfile.readline())
    if packet.get('id')==identifier:
     assert 'error' not in packet,'QMP_COMMAND_REJECTED'
     return packet.get('return')
  def read_until(predicate,seconds=120):
   deadline=time.monotonic()+seconds
   while time.monotonic()<deadline:
    if predicate(bytes(buffer)):return
    assert process.poll() is None,'QEMU_EXITED'
    time.sleep(.05)
   raise RuntimeError('SERIAL_DEADLINE')
  def shell(command,seconds=120):
   marker='ACCEPT_'+uuid.uuid4().hex
   console.sendall((command+"\nprintf '\\n"+marker[:7]+"''"+marker[7:]+"\\n'\n").encode())
   try:read_until(lambda data: ('\n'+marker+'\r').encode() in data or ('\n'+marker+'\n').encode() in data,seconds)
   except RuntimeError:
    print('DIAGNOSTIC:SHELL_OUTPUT_MARKER:'+str(marker.encode() in buffer),flush=True)
    raise
  def latest_auth():
   matches=re.findall(rb'dsh web: http://127\.0\.0\.1:3001/\?token=([^\s]+)(?:[ \t]|\r?\n)',buffer)
   assert matches,'AUTH_URL_MISSING'
   return matches[-1].decode()
  def page(auth,report=False):
   connection=http.client.HTTPConnection('127.0.0.1',39080,timeout=10)
   connection.request('GET','/?token='+auth,headers={'Host':'127.0.0.1:28080'})
   response=connection.getresponse()
   if report and response.status!=303:print('DIAGNOSTIC:AUTH_STATUS:'+str(response.status),flush=True)
   assert response.status==303,'AUTH_FAILED'
   cookie=response.getheader('Set-Cookie').split(';')[0];response.read()
   connection.request('GET','/',headers={'Host':'127.0.0.1:28080','Cookie':cookie})
   response=connection.getresponse();body=response.read()
   if report and (response.status!=200 or b'__DSH_BOOT__' not in body):print('DIAGNOSTIC:PAGE_STATUS:'+str(response.status),flush=True)
   assert response.status==200 and b'__DSH_BOOT__' in body,'PAGE_NOT_READY';connection.close()
  def ready_page():
   # The official auth URL can precede mounting all HTTP routes.
   deadline=time.monotonic()+90
   while time.monotonic()<deadline:
    try:page(latest_auth());return
    except (OSError,http.client.HTTPException,AssertionError):
     pass
     time.sleep(.5)
   page(latest_auth(),report=True)
  def transfer(route,method='GET',body=None):
   request=urllib.request.Request('http://127.0.0.1:39083'+route,method=method,data=body,headers=headers)
   with urllib.request.urlopen(request,timeout=180) as response:return response.read()
  def guest_health():
   nonce=uuid.uuid4().hex
   console.sendall(f'NODE_OPTIONS= NODE_COMPILE_CACHE= node /opt/harness/control.cjs {nonce} --handshake health\n'.encode())
   read_until(lambda data: ('HARNESS_CONTROL_READY:'+nonce+'\r\n').encode() in data,30)
   stamp=int(time.time()*1000);console.sendall(f'HARNESS_TIME:{nonce}:{stamp}\n'.encode())
   read_until(lambda data: re.search(('HARNESS_CONTROL:'+nonce+':[^\r\n]+\r?\n').encode(),data),10)
   reply=re.findall(('HARNESS_CONTROL:'+nonce+':([^\r\n]+)').encode(),buffer)
   return json.loads(reply[-1])
  try:
   stage='SOCKETPAIR';greeting=json.loads(qmpfile.readline());assert 'QMP' in greeting
   monitor('qmp_capabilities');assert monitor('query-status')['running']
   print('PASS:SOCKETPAIR_CONTROL',flush=True)
   stage='BOOT';read_until(lambda data:re.search(rb'dsh web: http://127\.0\.0\.1:3001/\?token=([^\s]+)\r?\n',data),300)
   ready_page();print('PASS:OFFICIAL_PAGE',flush=True)
   stage='CLOCK';result=guest_health();assert result['clock'] and result['running'] and result['writable']
   assert abs(result['epoch']/1000-time.time())<=2
   print('PASS:GUEST_CLOCK_AND_HEALTH',flush=True)
   stage='STORAGE_TOOLS'
   shell("for tool in script node npm corepack pnpm yarn bash git ssh curl xdg-user-dir resize2fs ls find grep sed gawk diff patch ps lsblk less file tar gzip xz zstd zip unzip rg jq nano; do command -v \"$tool\" >/dev/null || exit 1; done; test -f /usr/share/zoneinfo/Etc/UTC && echo TOOLS_''PRESENT")
   assert b'\nTOOLS_PRESENT' in buffer,'TOOLS_INVENTORY_MISSING'
   # Invoke the ELF programs too: a path alone does not prove shared libraries are present.
   shell("failed=0; for tool in nano less jq rg ssh file tar xz zstd lsblk; do case $tool in jq) args=\"-n 1\";; ssh) args=-V;; file) args=/opt/node/bin/node;; *) args=--version;; esac; if ! /usr/bin/$tool $args >/run/tool-$tool.log 2>&1; then echo TOOL_FAILED:$tool; failed=1; fi; done; test $failed = 0 && echo TOOLS_''RUN")
   assert b'\nTOOLS_RUN' in buffer,'TOOLS_EXECUTION_FAILED'
   shell("npm config get prefix >/run/npm-prefix; test \"$(cat /run/npm-prefix)\" = /root/.local && test \"$COREPACK_HOME\" = /root/.cache/corepack && echo PACKAGE_''PREFIX")
   assert b'\nPACKAGE_PREFIX' in buffer,'USER_PACKAGE_PREFIX_FAILED'
   shell("/bin/sh -c 'less --version >/run/posix-less && tar --version >/run/posix-tar' && echo POSIX_''GNU")
   assert b'\nPOSIX_GNU' in buffer,'POSIX_TOOLS_FAILED'
   shell("{ sleep 2; printf '\\030'; } | timeout 15 /usr/bin/script -qe -c '/usr/bin/nano /root/nano-probe' /run/nano-screen >/dev/null 2>&1 && echo NANO_''PTY")
   assert b'\nNANO_PTY' in buffer,'NANO_PTY_FAILED'
   print('PASS:REQUIRED_GUEST_TOOLS_AND_USER_PACKAGE_PREFIX',flush=True)
   stage='ONLINE_GROWTH'
   auth_before=latest_auth()
   shell("echo retained >/root/growth-sentinel")
   for size in [16,64]:
    stage='GROWTH_BEGIN_'+str(size)
    lease=json.loads(transfer('/storage/begin','POST',json.dumps({'bytes':size*1024**3}).encode()))['lease']
    stage='GROWTH_QMP_'+str(size)
    monitor('block_resize',{'device':'user','size':size*1024**3})
    stage='GROWTH_EXT4_'+str(size)
    result=json.loads(transfer('/storage/finish','POST',json.dumps({'lease':lease}).encode()))
    assert result['capacityBytes']==size*1024**3
    assert disk.stat().st_size==size*1024**3
   shell("grep -q '^retained$' /root/growth-sentinel && echo GROWTH_''PRESERVED")
   assert b'\nGROWTH_PRESERVED' in buffer
   assert latest_auth()==auth_before,'ONLINE_GROWTH_RESTARTED_HARNESS'
   ready_page()
   print('PASS:ONLINE_GROWTH_TO_64_GIB_PRESERVES_RUNNING_HARNESS_AND_DATA',flush=True)
   stage='FORWARD_REPAIR';monitor('human-monitor-command',{'command-line':'hostfwd_remove net0 tcp:127.0.0.1:39080'})
   assert monitor('human-monitor-command',{'command-line':'hostfwd_add net0 tcp:127.0.0.1:39080-10.0.2.15:2999'}).strip()==''
   ready_page();print('PASS:FORWARD_REPAIR_WITHOUT_VM_RESTART',flush=True)
   stage='PLUGIN';shell('dsh plugin --profile web add /root/projects/ipad-hello-plugin >/run/plugin-test.log 2>&1 && echo PLUGIN_''INSTALLED',180)
   assert b'\nPLUGIN_INSTALLED' in buffer
   shell('dsh --profile web --dump-config >/run/profile-test.json 2>/run/profile-test.log; grep -q ipad-hello /run/profile-test.json && echo PLUGIN_''COMPOSED')
   assert b'\nPLUGIN_COMPOSED' in buffer
   print('PASS:OFFICIAL_PLUGIN_INSTALL_AND_COMPOSITION',flush=True)
   stage='PREVIEW';server="const h=require('node:http').createServer((q,r)=>r.end('live-dev'));h.on('upgrade',(q,s)=>{s.write('HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r\\n');s.on('data',d=>s.write(d));s.on('end',()=>s.destroy());});h.listen(5173,'127.0.0.1');"
   server+="const v6=require('node:http').createServer((q,r)=>r.end('ipv6-dev'));v6.listen({port:5174,host:'::1',ipv6Only:true});"
   shell("node -e "+shlex.quote(server)+" >/run/dev-test.log 2>&1 &")
   stage='PREVIEW_CATALOG'
   request=urllib.request.Request('http://127.0.0.1:39084/ports',headers=headers)
   deadline=time.monotonic()+30
   ports=[]
   while time.monotonic()<deadline:
    with urllib.request.urlopen(request,timeout=20) as response:ports=json.load(response)['ports']
    if {5173,5174}.issubset({item['port'] for item in ports}):break
    time.sleep(1)
   assert {5173,5174}.issubset({item['port'] for item in ports})
   stage='PREVIEW_HTTP'
   with urllib.request.urlopen('http://127.0.0.1:39000/',timeout=20) as response:assert response.read()==b'live-dev'
   stage='PREVIEW_WEBSOCKET'
   ws=socket.create_connection(('127.0.0.1',39000),timeout=10)
   ws.sendall(b'GET / HTTP/1.1\r\nHost: 127.0.0.1:39000\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: test\r\nSec-WebSocket-Version: 13\r\n\r\n')
   assert b'101 Switching' in ws.recv(4096);ws.sendall(b'\x81\x01x');assert ws.recv(4096)==b'\x81\x01x';ws.close()
   print('PASS:LOOPBACK_HTTP_AND_WEBSOCKET_PREVIEW',flush=True)
   stage='PREVIEW_IPV6'
   relay=next(item['relayPort'] for item in ports if item['port']==5174)
   assert monitor('human-monitor-command',{'command-line':f'hostfwd_add net0 tcp:127.0.0.1:39001-10.0.2.15:{relay}'}).strip()==''
   with urllib.request.urlopen('http://127.0.0.1:39001/',timeout=20) as response:assert response.read()==b'ipv6-dev'
   print('PASS:IPV6_LOOPBACK_PREVIEW',flush=True)
   stage='FROZEN_CONTROL'
   shell('/bin/busybox dd if=/dev/zero of=/root/freeze-probe bs=1048576 count=32 2>/dev/null')
   previous=latest_auth()
   request=urllib.request.Request('http://127.0.0.1:39083/userdata/archive',headers=headers)
   stream=urllib.request.urlopen(request,timeout=180)
   assert len(stream.read(262144))==262144
   result=guest_health();assert result['leased'] and not result['writable'] and result['clock']
   try:
    transfer('/storage/begin','POST',json.dumps({'bytes':64*1024**3}).encode())
    raise AssertionError('GROWTH_ACCEPTED_DURING_BACKUP')
   except urllib.error.HTTPError as error:
    assert json.loads(error.read())['error']=='BACKUP_BUSY'
   shell('true')
   print('PASS:CONTROL_DURING_FROZEN_BACKUP',flush=True)
   stream.close()
   stage='BACKUP_ABORT'
   read_until(lambda data:latest_auth()!=previous,180);ready_page()
   shell('rm /root/freeze-probe')
   print('PASS:ABORTED_BACKUP_THAWS_AND_RESTARTS',flush=True)
   stage='BACKUP';shell("mkdir -p /root/projects/backup-probe; echo saved >/root/projects/backup-probe/value; echo private-test >/root/.git-credentials")
   previous=latest_auth()
   backup=transfer('/userdata/archive');assert len(backup)>1024
   print('PASS:COORDINATED_EXT4_BACKUP',flush=True)
   stage='BACKUP_RESTART'
   read_until(lambda data:latest_auth()!=previous,180)
   ready_page();previous=latest_auth()
   print('PASS:BACKUP_OFFICIAL_PROFILE_RESTART',flush=True)
   stage='RESTORE_MUTATE';shell('echo altered >/root/projects/backup-probe/value')
   stage='RESTORE_REQUEST'
   restored=json.loads(transfer('/userdata/restore','POST',backup));assert restored['restored']
   stage='RESTORE_VERIFY'
   shell("grep -q '^saved$' /root/projects/backup-probe/value && test ! -e /root/.git-credentials && echo RESTORE_''VERIFIED",30)
   assert b'\nRESTORE_VERIFIED' in buffer
   # Wait for the official profile with its reconstructed local plugin to boot.
   stage='RESTORE_RESTART'
   read_until(lambda data:latest_auth()!=previous,180)
   ready_page();print('PASS:FULL_RESTORE_AND_OFFICIAL_PROFILE_RESTART',flush=True)
   stage='INVALID_RESTORE'
   try:transfer('/userdata/restore','POST',b'corrupt archive');raise AssertionError('BAD_ARCHIVE_ACCEPTED')
   except urllib.error.HTTPError as error:assert error.code>=400
   shell("grep -q '^saved$' /root/projects/backup-probe/value && echo ORIGINAL_''PRESERVED")
   assert b'\nORIGINAL_PRESERVED' in buffer
   print('PASS:INVALID_RESTORE_PRESERVES_DATA',flush=True)
   stage='TRASH';transfer('/projects/backup-probe','DELETE');transfer('/trash','DELETE')
   print('PASS:PROJECT_TRASH_AND_PURGE',flush=True)
  except Exception as error:
   if isinstance(error,AssertionError) and str(error) in ['AUTH_FAILED','PAGE_NOT_READY','TOOLS_INVENTORY_MISSING','TOOLS_EXECUTION_FAILED','USER_PACKAGE_PREFIX_FAILED','NANO_PTY_FAILED','POSIX_TOOLS_FAILED']:
    print('DIAGNOSTIC:'+str(error),flush=True)
    for tool in re.findall(rb'\nTOOL_FAILED:([a-z]+)\r?\n',buffer):print('DIAGNOSTIC:TOOL_FAILED:'+tool.decode(),flush=True)
   if b'Out of memory' in buffer or b'Killed process' in buffer:print('DIAGNOSTIC:GUEST_OOM',flush=True)
   if b'Buffer I/O error' in buffer or b'EXT4-fs error' in buffer:print('DIAGNOSTIC:GUEST_IO_ERROR',flush=True)
   print('DIAGNOSTIC:AUTH_LAUNCH_COUNT:'+str(len(re.findall(rb'dsh web: http://127\.0\.0\.1:3001/\?token=',buffer))),flush=True)
   if isinstance(error,urllib.error.HTTPError):print('DIAGNOSTIC:HTTP_STATUS:'+str(error.code),flush=True)
   elif isinstance(error,RuntimeError) and str(error) in ['SERIAL_DEADLINE','QEMU_EXITED']:
    print('DIAGNOSTIC:'+str(error),flush=True)
   else:print('DIAGNOSTIC:EXCEPTION_TYPE:'+type(error).__name__,flush=True)
   raise
  finally:
   stop_serial.set();console.close();serial_reader.join(timeout=1);control.close();qmpfile.close();process.kill();process.wait();log.close()
try:main()
except Exception:
 print('FAIL:'+stage,flush=True)
 raise SystemExit(1)
