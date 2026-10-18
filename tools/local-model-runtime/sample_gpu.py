"""Sample per-process IORegistry GPU-time deltas; these are not additive GPU shares."""
import argparse
import json
import plistlib
import re
import subprocess
import time
from pathlib import Path


def sample():
    start=time.monotonic()
    data=plistlib.loads(subprocess.check_output(['ioreg','-a','-l','-w','0']))
    end=time.monotonic();rows={};devices=[]
    def walk(node):
        if isinstance(node,dict):
            if 'PerformanceStatistics' in node:
                stats=node['PerformanceStatistics']
                if 'Device Utilization %' in stats:devices.append(stats)
            match=re.match(r'pid (\d+), (.*)',node.get('IOUserClientCreator',''))
            if match and 'AppUsage' in node:
                row=rows.setdefault(int(match[1]),dict(name=match[2],nanoseconds=0))
                row['nanoseconds']+=sum(a.get('accumulatedGPUTime',0) for a in node['AppUsage'])
            for value in node.values():walk(value)
        elif isinstance(node,list):
            for value in node:walk(value)
    walk(data)
    return (start+end)/2,rows,devices


def main():
    ap=argparse.ArgumentParser();ap.add_argument('output',type=Path);args=ap.parse_args()
    start,a,_=sample();time.sleep(3);end,b,devices=sample();elapsed=end-start
    rows=[dict(pid=pid,name=r['name'],gpu_time_delta_percent=round(
        100*(r['nanoseconds']-a[pid]['nanoseconds'])/1e9/elapsed,2))
        for pid,r in b.items() if pid in a]
    rows.sort(key=lambda r:r['gpu_time_delta_percent'],reverse=True)
    report=dict(sample_seconds=elapsed,interpretation='GPU elapsed-time deltas, not normalized core utilization or additive shares',
        processes=rows[:10],device_statistics=devices)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()
