#!/usr/bin/env python3
from __future__ import annotations
import argparse, csv, re
from pathlib import Path

XCZU15EG_CAPACITY = {
    'clb_luts': 341280,
    'lut_logic': 341280,
    'lut_memory': 184320,
    'clb_registers': 682560,
    'bram_tiles': 744,
    'dsps': 3528,
}

def find_report(d:Path, names):
    for n in names:
        p=d/n
        if p.is_file(): return p
    return None

def table_value(text,label):
    m=re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([0-9.]+)\s*\|.*?\|\s*([0-9.]+)\s*\|\s*$',text,re.M)
    return (m.group(1),m.group(2)) if m else ('','')

def hierarchical_top_values(text):
    """Parse the top row of a report_utilization -hierarchical table."""
    for line in text.splitlines():
        parts=[part.strip() for part in line.strip().strip('|').split('|')]
        if len(parts) != 11 or parts[0] != 'attention_board_top' or parts[1] != '(top)':
            continue
        try:
            nums=[float(value) for value in parts[2:]]
        except ValueError:
            continue
        used={
            'clb_luts': nums[0],
            'lut_logic': nums[1],
            'lut_memory': nums[2] + nums[3],
            'clb_registers': nums[4],
            'bram_tiles': nums[5] + 0.5*nums[6],
            'dsps': nums[8],
        }
        values={}
        for key,value in used.items():
            values[key]=f'{value:g}'
            values[key+'_util_pct']=f'{100.0*value/XCZU15EG_CAPACITY[key]:.2f}'
        return values
    return {}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--reports',type=Path,default=Path('reports'))
    ap.add_argument('--out-dir',type=Path,default=None); args=ap.parse_args()
    out=args.out_dir or args.reports; out.mkdir(parents=True,exist_ok=True)
    util=find_report(args.reports,['utilization_impl.rpt','post_route_utilization.rpt'])
    timing=find_report(args.reports,['timing_summary_impl.rpt','post_route_timing_summary.rpt'])
    power=find_report(args.reports,['power_impl.rpt','post_route_power.rpt'])
    if not util or not timing: raise SystemExit('utilization/timing report not found')
    ut=util.read_text(errors='replace'); tt=timing.read_text(errors='replace')
    data={}
    for key,label in [('clb_luts','CLB LUTs'),('lut_logic','LUT as Logic'),('lut_memory','LUT as Memory'),
                      ('clb_registers','CLB Registers'),('bram_tiles','Block RAM Tile'),('dsps','DSPs')]:
        data[key],data[key+'_util_pct']=table_value(ut,label)
    if not data['clb_luts']:
        data.update(hierarchical_top_values(ut))
    if not data.get('clb_luts'):
        raise SystemExit('resource summary/top hierarchy row not found')
    # Parse the first all-numeric row under Design Timing Summary. Vivado's
    # columns are WNS, TNS, fail/total endpoints, WHS, THS, ...
    data.update(wns_ns='',tns_ns='',whs_ns='',ths_ns='')
    timing_block = tt.split('Design Timing Summary', 1)[-1]
    for line in timing_block.splitlines():
        tokens = line.split()
        if len(tokens) >= 12 and all(re.fullmatch(r'-?[0-9]+(?:\.[0-9]+)?', x) for x in tokens[:12]):
            data.update(wns_ns=tokens[0], tns_ns=tokens[1],
                        whs_ns=tokens[4], ths_ns=tokens[5])
            break
    clocks=[]
    for name,period,freq in re.findall(r'^\s*(\S+)\s+\{[^}]+\}\s+([0-9.]+)\s+([0-9.]+)\s*$',tt,re.M):
        clocks.append((name,period,freq))
    data['clock_summary']='; '.join(f'{n}:{f}MHz/{p}ns' for n,p,f in clocks)
    timing_lower=tt.lower()
    data['timing_met']='no' if 'timing constraints are not met' in timing_lower else \
        'yes' if ('timing constraints are met' in timing_lower or
                  'all user specified timing constraints are met' in timing_lower) else 'unknown'
    data['estimated_power_w']=''
    data['power_confidence']=''
    if power:
        pt=power.read_text(errors='replace')
        m=re.search(r'Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)',pt)
        if not m: m=re.search(r'Total On-Chip Power.*?([0-9]+\.[0-9]+)',pt)
        if m: data['estimated_power_w']=m.group(1)
        m=re.search(r'Confidence Level\s*\|\s*([^|\n]+)',pt)
        if m: data['power_confidence']=m.group(1).strip()
    csvp=out/'ppa_summary.csv'; mdp=out/'ppa_summary.md'
    with csvp.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=list(data)); w.writeheader(); w.writerow(data)
    md=['# PPA Summary','',f'- Timing met: {data["timing_met"]}',f'- Clock summary: {data["clock_summary"]}',
        f'- WNS/TNS: {data["wns_ns"]} ns / {data["tns_ns"]} ns',f'- WHS/THS: {data["whs_ns"]} ns / {data["ths_ns"]} ns','',
        '| Resource | Used | Utilization |','|---|---:|---:|']
    for key,title in [('clb_luts','CLB LUTs'),('lut_logic','LUT as Logic'),('lut_memory','LUT as Memory'),
                      ('clb_registers','CLB Registers'),('bram_tiles','BRAM tiles'),('dsps','DSPs')]:
        md.append(f'| {title} | {data[key]} | {data[key+"_util_pct"]}% |')
    if data['estimated_power_w']: md += ['',f'- Estimated on-chip power: {data["estimated_power_w"]} W',f'- Power confidence: {data["power_confidence"]}']
    mdp.write_text('\n'.join(md)+'\n',encoding='utf-8')
    print('[PASS] PPA summary created'); print(csvp); print(mdp)
if __name__=='__main__': main()
