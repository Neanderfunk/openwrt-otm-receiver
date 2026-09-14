#!/usr/bin/env python3
# Wartet, bis der AVM-Bootloader EVA per FTP antwortet, und laedt dann ein
# Initramfs in den RAM - dieselben Befehle wie OpenWrts
# scripts/flashing/eva_ramboot.py (lantiq: Adresse aus Image-Groesse), aber:
#   - wiederholt den Verbindungsaufbau, bis das kurze EVA-Fenster nach dem
#     Einschalten getroffen ist,
#   - optional ueber einen SOCKS5-Proxy (--socks host:port), z. B. ssh -D auf
#     einen Router, der im selben Segment wie die Box haengt.
#
# Aufruf: eva_ramboot_warten.py [--socks 127.0.0.1:10801] 192.168.178.1 initramfs.bin

import argparse
import socket
import sys
import time
from ftplib import FTP
from os import stat

p = argparse.ArgumentParser()
p.add_argument('ip')
p.add_argument('image')
p.add_argument('--socks', help='SOCKS5-Proxy host:port')
p.add_argument('--timeout', type=float, default=300, help='max. Wartezeit in s')
args = p.parse_args()

if args.socks:
	import socks  # PySocks
	h, port = args.socks.rsplit(':', 1)
	socks.set_default_proxy(socks.SOCKS5, h, int(port))
	socket.socket = socks.socksocket

size = stat(args.image).st_size
assert size < 0x2000000
addr = ((0x8000000 - size) & ~0xfff)
haddr = 0x80000000 + addr

start = time.monotonic()
tries = 0
while True:
	tries += 1
	try:
		ftp = FTP(args.ip, 'adam2', 'adam2', timeout=3)
		break
	except Exception as e:
		if time.monotonic() - start > args.timeout:
			sys.exit('EVA nach %d s nicht erreicht (%d Versuche, zuletzt: %s)' % (args.timeout, tries, e))
		time.sleep(0.3)
print('EVA erreicht nach %.1f s, Versuch %d' % (time.monotonic() - start, tries), flush=True)

def adam(cmd):
	print('> %s' % cmd, flush=True)
	resp = ftp.sendcmd(cmd)
	print('< %s' % resp, flush=True)
	assert resp[0:3] == '200'

ftp.set_pasv(True)
adam('SETENV memsize 0x%08x' % addr)
adam('SETENV kernel_args_tmp mtdram1=0x%08x,0x88000000' % haddr)
adam('MEDIA SDRAM')
with open(args.image, 'rb') as img:
	ftp.storbinary('STOR 0x%08x 0x88000000' % haddr, img)
ftp.close()
print('Image uebertragen (%d Byte), Box bootet jetzt aus dem RAM' % size, flush=True)
