#!/usr/bin/env bash
# vole history - show what Vole removed (from ~/.local/state/vole/operations.log)

cmd_history() {
    local json=0 limit=20 a
    for a in "$@"; do case "$a" in --json) json=1 ;; --all) limit=100000 ;; -h|--help) echo "Usage: vo history [--json] [--all]"; return ;; esac; done
    [[ -f "$VOLE_OPLOG" ]] || { (( json )) && echo '{"sessions":[]}' || say "No cleanup history yet."; return 0; }
    awk -F'\t' -v json="$json" -v limit="$limit" '
    function human(b,  u,i){ split("B KB MB GB TB",u," "); i=1; while(b>=1024&&i<5){b/=1024;i++} return (i==1)? sprintf("%dB",b) : sprintf("%.1f%s",b,u[i]) }
    function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/," ",s); return s }
    {
        ts=$1; run=$2; cmd=$3; act=$4; bytes=$5+0; det=$6
        if (!(run in seen)) { seen[run]=1; order[++n]=run; cmdof[run]=cmd; start[run]=ts; ended[run]="" }
        if (act=="run-end") { ended[run]=ts; next }
        if (act=="run-start") next
        cnt[run]++; tot[run]+=bytes
        if (cnt[run]<=200) items[run, cnt[run]]=act "\t" bytes "\t" det
    }
    END {
        first = (n>limit)? n-limit+1 : 1
        if (json) {
            printf "{\"sessions\":["
            for (i=first;i<=n;i++){ r=order[i]
                printf "%s{\"run_id\":\"%s\",\"command\":\"%s\",\"started_at\":\"%s\",\"ended_at\":\"%s\",\"actions\":%d,\"bytes\":%d,\"items\":[", (i>first?",":""), esc(r), esc(cmdof[r]), start[r], ended[r], cnt[r], tot[r]
                m=(cnt[r]>200)?200:cnt[r]
                for (j=1;j<=m;j++){ split(items[r,j],f,"\t"); printf "%s{\"action\":\"%s\",\"bytes\":%d,\"detail\":\"%s\"}", (j>1?",":""), esc(f[1]), f[2], esc(f[3]) }
                printf "]}"
            }
            print "]}"
        } else {
            for (i=n;i>=first;i--){ r=order[i]
                printf "\033[1m%s  %-10s\033[0m %d actions, %s%s\n", start[r], cmdof[r], cnt[r], human(tot[r]), (ended[r]==""?"  (no end marker)":"")
                m=(cnt[r]>5)?5:cnt[r]
                for (j=1;j<=m;j++){ split(items[r,j],f,"\t"); printf "    %-14s %9s  %s\n", f[1], human(f[2]), f[3] }
                if (cnt[r]>5) printf "    … %d more\n", cnt[r]-5
            }
        }
    }' "$VOLE_OPLOG"
}
