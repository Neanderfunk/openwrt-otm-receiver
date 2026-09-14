#!/usr/bin/env python3
# Wertet pcap-Mitschnitte (DLT 127, Radiotap) von mon0 aus: je Datei gute vs.
# CRC-fehlerhafte Frames, Signal (dBm), Raten, Kanal-Flags (0x4000 = Half-Rate),
# und ob der 802.11-Header wie ITS aussieht (LLC/SNAP, Ethertype 0x8947).
# Fuer CRC-fehlerhafte Frames muss mit einem fcsfail-Monitor mitgeschnitten
# werden (iw phy X interface add monf type monitor flags fcsfail otherbss).
# Aufruf: radiotap-auswertung.py datei.pcap [...]
import struct,sys,collections,statistics
# (Groesse, Ausrichtung) je Radiotap-Feld im Standard-Namespace, Bits 0..14
F={0:(8,8),1:(1,1),2:(1,1),3:(4,2),4:(2,1),5:(1,1),6:(1,1),7:(2,2),8:(2,2),9:(2,2),10:(1,1),11:(1,1),12:(1,1),13:(1,1),14:(2,2)}
def parse(path):
    d=open(path,'rb').read(); magic=struct.unpack('<I',d[:4])[0]; e='<' if magic==0xa1b2c3d4 else '>'
    i=24; out=[]
    while i+16<=len(d):
        ts,tu,cl,ol=struct.unpack(e+'IIII',d[i:i+16]); p=d[i+16:i+16+cl]; i+=16+cl
        ver,pad,ln=struct.unpack('<BBH',p[:4]); words=[]; o=4
        while True:
            w=struct.unpack('<I',p[o:o+4])[0]; words.append(w); o+=4
            if not w&0x80000000: break
        pres=words[0]; r={'flags':0}
        for b in range(15):
            if not pres&(1<<b): continue
            sz,al=F[b]; o=(o+al-1)//al*al; v=p[o:o+sz]; o+=sz
            if b==1: r['flags']=v[0]
            elif b==2: r['rate']=v[0]/2
            elif b==3: r['freq'],r['chflags']=struct.unpack('<HH',v)
            elif b==5: r['sig']=struct.unpack('b',v)[0]
            elif b==6: r['noise']=struct.unpack('b',v)[0]
        f=p[ln:]; r['len']=len(f)
        fc=f[0] if f else 0; typ=(fc>>2)&3; sub=fc>>4
        hl=24+(2 if (typ==2 and sub&8) else 0)
        r['bcast']= len(f)>=10 and f[4:10]==b'\xff'*6
        r['its']= typ==2 and len(f)>=hl+8 and f[hl:hl+6]==b'\xaa\xaa\x03\x00\x00\x00' and f[hl+6:hl+8]==b'\x89\x47'
        r['bad']= bool(r['flags']&0x40)
        out.append(r)
    return out
for path in sys.argv[1:]:
    fr=parse(path); good=[x for x in fr if not x['bad']]; bad=[x for x in fr if x['bad']]
    print(f"== {path}: {len(fr)} Frames, gut {len(good)}, CRC-fehlerhaft {len(bad)}")
    for name,grp in (('gut',good),('CRC-fehler',bad)):
        if not grp: continue
        s=[x['sig'] for x in grp if 'sig' in x]
        print(f"  {name:10s}: Signal dBm min/median/max = {min(s)}/{statistics.median(s):.0f}/{max(s)}  |  ITS-Header erkennbar {sum(x['its'] for x in grp)}/{len(grp)}  Broadcast {sum(x['bcast'] for x in grp)}  | Raten {dict(collections.Counter(x.get('rate') for x in grp).most_common(4))}  Laenge median {statistics.median(x['len'] for x in grp):.0f}")
    cf=collections.Counter((x.get('freq'),hex(x.get('chflags',0))) for x in fr).most_common(2); print("  Kanal/Flags:", cf)
    hist=collections.Counter((x['sig']//5)*5 for x in bad if 'sig' in x); print("  CRC-Fehler je Signal (5-dB-Klassen):", dict(sorted(hist.items())))
