#!/usr/bin/env python3
from __future__ import annotations
import argparse, csv, re, statistics
from pathlib import Path

FIELDS = [
    'run','total_cycles','v_load_cycles','core_run_cycles','raw_wait_cycles',
    'raw_busy_cycles','bc_busy_cycles','pv_busy_cycles','context_busy_cycles',
    'context_backpressure_cycles','ddr_read_busy_cycles','ddr_write_busy_cycles',
    'raw_req_count','read_beat_count','write_beat_count','context_word_count',
    'group0_cycles','group1_cycles','group2_cycles','group3_cycles',
    'group4_cycles','group5_cycles','group6_cycles','group7_cycles',
    'read_command_count','write_command_count','error_detail']

FINE_FIELDS = [
    'run','rope_busy_cycles','qk_busy_cycles','mask_busy_cycles',
    'softmax_busy_cycles','bc_backend_busy_cycles','capture_busy_cycles',
    'context_transfer_cycles','bc_pv_overlap_cycles','core_idle_cycles',
    'repack_stall_cycles','pv_feed_stall_cycles','softmax_stall_cycles',
    'interstage_wait_cycles']

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('log',type=Path)
    ap.add_argument('--out-dir',type=Path,default=Path('.'))
    args=ap.parse_args(); text=args.log.read_text(encoding='utf-8',errors='replace')
    rows=[]
    fine_rows={}
    for line in text.splitlines():
        if line.startswith('HWPROF_CSV,'):
            vals=line.strip().split(',')[1:]
            if len(vals)!=len(FIELDS):
                raise SystemExit(f'Unexpected HWPROF_CSV field count {len(vals)}')
            rows.append(dict(zip(FIELDS,(int(v,0) for v in vals))))
        elif line.startswith('HWPROF_FINE_CSV,'):
            vals=line.strip().split(',')[1:]
            if len(vals)!=len(FINE_FIELDS):
                raise SystemExit(f'Unexpected HWPROF_FINE_CSV field count {len(vals)}')
            row=dict(zip(FINE_FIELDS,(int(v,0) for v in vals)))
            fine_rows[row['run']]=row
    if not rows: raise SystemExit('No HWPROF_CSV lines found')
    if fine_rows:
        for row in rows:
            if row['run'] not in fine_rows:
                raise SystemExit(f'Missing HWPROF_FINE_CSV for run {row["run"]}')
            row.update({k:v for k,v in fine_rows[row['run']].items() if k!='run'})
    output_fields=FIELDS + (FINE_FIELDS[1:] if fine_rows else [])
    args.out_dir.mkdir(parents=True,exist_ok=True)
    csv_path=args.out_dir/'v23_hardware_profile_runs.csv'
    with csv_path.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=output_fields); w.writeheader(); w.writerows(rows)
    avg={k:round(statistics.mean(r[k] for r in rows),3) for k in output_fields if k!='run'}
    total=avg['total_cycles']
    def pct(k): return 0 if not total else avg[k]*100/total
    md=[
      '# v2.3 Hardware Profiling Summary','',
      f'- Runs: {len(rows)}', f'- Average total PL cycles: {avg["total_cycles"]:,.3f}',
      '', '| Counter | Average cycles/count | % of total cycles |','|---|---:|---:|']
    for k in ['v_load_cycles','core_run_cycles','bc_busy_cycles','pv_busy_cycles',
              'raw_wait_cycles','raw_busy_cycles','ddr_read_busy_cycles',
              'context_busy_cycles','context_backpressure_cycles','ddr_write_busy_cycles']:
        md.append(f'| {k} | {avg[k]:,.3f} | {pct(k):.3f}% |')
    if fine_rows:
        for k in FINE_FIELDS[1:]:
            md.append(f'| {k} | {avg[k]:,.3f} | {pct(k):.3f}% |')
        overlap_base=min(avg['bc_busy_cycles'],avg['pv_busy_cycles'])
        overlap_eff=0 if overlap_base == 0 else 100*avg['bc_pv_overlap_cycles']/overlap_base
        md += ['',f'- B+C/PV overlap efficiency: {overlap_eff:.3f}%']
    md += ['', '## Traffic', '']
    for k in ['raw_req_count','read_command_count','read_beat_count',
              'write_command_count','write_beat_count','context_word_count','error_detail']:
        md.append(f'- {k}: {avg[k]:,.3f}')
    md += ['', '## Per-group cycles', '']
    for g in range(8): md.append(f'- Group {g}: {avg[f"group{g}_cycles"]:,.3f}')
    md += ['', '> Busy/wait counters overlap and must not be added as exclusive phases.','']
    md_path=args.out_dir/'v23_hardware_profile_summary.md'
    md_path.write_text('\n'.join(md),encoding='utf-8')
    print(f'[PASS] parsed {len(rows)} runs')
    print(csv_path); print(md_path)
if __name__=='__main__': main()
