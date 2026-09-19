#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
codex-session-digest.py —— 把 Codex 的 rollout-*.jsonl 会话记录榨成「项目经验包」

会话文件里 95%+ 是工具调用的原始输出（文件全文、命令 stdout、图片 base64），
真正的经验只占极小比例。本工具只保留：
  * 你提出的需求（用户消息，完整保留）
  * 助手的结论与方案（助手消息，长的截断）
  * 碰过的文件、跑过的命令（去重清单）
  * 报错信息（便于回顾踩过的坑）
丢掉所有原始工具输出，压缩比通常 100:1 ~ 1000:1。

用法：
  python3 codex-session-digest.py --probe          先看格式（不确定结构时先跑这个）
  python3 codex-session-digest.py                  生成经验包（默认扫 ~/.codex 下的会话目录）
  python3 codex-session-digest.py --out ~/Desktop/codex-经验包
  python3 codex-session-digest.py --dirs ~/.codex/sessions ~/.codex/archived_sessions

生成的 Markdown 可直接复制粘贴进新对话窗口作为上下文。
不会修改或删除任何原始文件。
"""

import argparse, json, os, re, sys
from collections import Counter, OrderedDict
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------- 配置
WRAPPER_KEYS = ('item', 'payload', 'msg', 'data', 'event', 'record', 'body')
ASSISTANT_CHARS = 1200      # 助手单条消息保留多少字符
USER_CHARS = 4000           # 用户单条消息保留多少字符（需求描述，尽量全留）
ERROR_CHARS = 400
MAX_LIST = 60               # 文件/命令清单最多列几条

PATH_RE = re.compile(r'(?:^|[\s"\'(])((?:~|/|\./)[\w./\-一-鿿]{3,120}\.\w{1,8})')
# 注意 \w*：不加的话 \berror\b 匹配不到 KeyError / ValueError 这类驼峰异常名
ERR_RE = re.compile(r'(?i)(traceback|\w*error\b|\w*exception\b|\bfailed\b|\bfatal\b|\bpanic\b)')
# 真正有信息量的那一行：ValueError: xxx / KeyError: xxx / error: xxx
ERR_SPECIFIC_RE = re.compile(r'(?i)^[\w.]*(?:error|exception)\b\s*:|^\s*(?:error|fatal)\s*:')


def unwrap(rec):
    """剥掉常见的一层包装，拿到真正的消息体。"""
    seen = 0
    while isinstance(rec, dict) and seen < 4:
        for k in WRAPPER_KEYS:
            inner = rec.get(k)
            if isinstance(inner, dict):
                rec = inner
                break
        else:
            break
        seen += 1
    return rec


def collect_text(node, depth=0, budget=8):
    """从任意嵌套结构里收集人类可读文本（只走 text 类字段，不碰工具输出）。"""
    if depth > budget:
        return []
    out = []
    if isinstance(node, str):
        return [node]
    if isinstance(node, dict):
        for key in ('text', 'input_text', 'output_text', 'summary', 'content', 'message'):
            if key in node:
                out.extend(collect_text(node[key], depth + 1, budget))
        return out
    if isinstance(node, list):
        for x in node:
            out.extend(collect_text(x, depth + 1, budget))
    return out


def squeeze(s, limit):
    s = re.sub(r'\n{3,}', '\n\n', (s or '').strip())
    if len(s) <= limit:
        return s
    return s[:limit].rstrip() + f'\n\n…（截断，原文 {len(s)} 字）'


class Digest:
    """一个会话的提炼结果。"""
    def __init__(self, path):
        self.path = path
        self.size = path.stat().st_size
        self.mtime = datetime.fromtimestamp(path.stat().st_mtime)
        self.users, self.assistants, self.errors = [], [], []
        self.files, self.cmds = Counter(), Counter()
        self.lines = self.bad = 0
        self.kinds = Counter()

    def feed(self, raw):
        self.lines += 1
        try:
            rec = json.loads(raw)
        except Exception:
            self.bad += 1
            return
        if not isinstance(rec, dict):
            return
        rec = unwrap(rec)
        rtype = str(rec.get('type') or rec.get('item_type') or rec.get('kind') or '')
        role = str(rec.get('role') or rec.get('author') or '')
        self.kinds[role or rtype or '?'] += 1

        # 文件路径与命令：从整行原文里抓，比逐字段找更稳
        for m in PATH_RE.finditer(raw[:20000]):
            p = m.group(1)
            if not any(x in p for x in ('/node_modules/', '/.git/', 'site-packages')):
                self.files[p] += 1
        # 命令：从解析后的 arguments 里取（它常是一层 JSON 字符串，正则对付转义引号不可靠）
        if 'function_call' in rtype or 'tool' in rtype or 'shell' in rtype:
            args = rec.get('arguments') or rec.get('input') or rec.get('args')
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except Exception:
                    args = {'command': args[:300]}
            if isinstance(args, dict):
                for k in ('command', 'cmd', 'shell', 'script'):
                    v = args.get(k)
                    if v:
                        v = ' '.join(str(x) for x in v) if isinstance(v, list) else str(v)
                        self.cmds[squeeze(v, 160)] += 1
                        break

        # 消息正文
        if role == 'user' or rtype in ('user_message', 'user'):
            for t in collect_text(rec):
                t = t.strip()
                if len(t) > 8 and not t.startswith('<'):
                    self.users.append(squeeze(t, USER_CHARS))
        elif role == 'assistant' or rtype in ('assistant_message', 'assistant', 'message'):
            for t in collect_text(rec):
                t = t.strip()
                if len(t) > 24:
                    self.assistants.append(squeeze(t, ASSISTANT_CHARS))
        # 报错：只在工具输出里找，且只留一行上下文
        elif 'output' in rtype or 'result' in rtype:
            blob = rec.get('output') or rec.get('result') or rec.get('stdout') or ''
            if not isinstance(blob, str):
                blob = json.dumps(blob, ensure_ascii=False)
            hits = [l.strip() for l in blob[:8000].splitlines()
                    if l.strip() and ERR_RE.search(l)]
            if hits:
                # 优先取「KeyError: xxx」这类具体的那一行，而不是 Traceback 首行
                specific = [h for h in hits if ERR_SPECIFIC_RE.search(h)]
                self.errors.append(squeeze((specific or hits)[0], ERROR_CHARS))

    @property
    def kept_chars(self):
        return sum(len(x) for x in self.users + self.assistants + self.errors)

    def to_markdown(self):
        L = [f'## {self.path.name}', '']
        L.append(f'- 时间：{self.mtime:%Y-%m-%d %H:%M}')
        L.append(f'- 原始大小：{self.size/1048576:.1f} MB，{self.lines} 条记录')
        if self.bad:
            L.append(f'- 无法解析的行：{self.bad}')
        L.append('')

        if self.users:
            L += ['### 需求与指令', '']
            for i, t in enumerate(self.users, 1):
                L += [f'**{i}.** {t}', '']
        if self.assistants:
            L += ['### 结论与方案', '']
            for t in self.assistants[-40:]:   # 结论多在后半段
                L += [f'- {t}', '']
        if self.errors:
            uniq = list(OrderedDict.fromkeys(self.errors))[:20]
            L += ['### 遇到的报错', '']
            L += [f'- `{e}`' for e in uniq] + ['']
        if self.files:
            L += ['### 涉及的文件', '']
            L += [f'- `{p}`（{n} 次）' for p, n in self.files.most_common(MAX_LIST)] + ['']
        if self.cmds:
            L += ['### 跑过的命令', '']
            L += [f'- `{c}`' for c, _ in self.cmds.most_common(MAX_LIST)] + ['']
        return '\n'.join(L)


def probe(files, n=3):
    print('=== 格式探测：以下是前几行的结构 ===\n')
    for f in files[:n]:
        print(f'--- {f.name}（{f.stat().st_size/1048576:.1f} MB）---')
        with f.open(encoding='utf-8', errors='replace') as fh:
            for i, line in enumerate(fh):
                if i >= 4:
                    break
                try:
                    rec = json.loads(line)
                except Exception:
                    print(f'  [{i}] 非 JSON：{line[:120]}')
                    continue
                if isinstance(rec, dict):
                    keys = ', '.join(list(rec.keys())[:12])
                    inner = unwrap(rec)
                    extra = ''
                    if inner is not rec and isinstance(inner, dict):
                        extra = f'  →内层键: {", ".join(list(inner.keys())[:12])}'
                    print(f'  [{i}] 顶层键: {keys}{extra}')
                    print(f'      role={rec.get("role") or (inner.get("role") if isinstance(inner,dict) else None)!r}'
                          f' type={rec.get("type") or (inner.get("type") if isinstance(inner,dict) else None)!r}')
        print()


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('--dirs', nargs='*', default=None, help='会话目录，默认自动找 ~/.codex 下的')
    ap.add_argument('--out', default=str(Path.home() / 'Desktop' / 'codex-经验包'))
    ap.add_argument('--probe', action='store_true', help='只探测格式，不生成')
    ap.add_argument('--min-mb', type=float, default=0.0, help='只处理大于这个体积的文件')
    args = ap.parse_args()

    if args.dirs:
        dirs = [Path(os.path.expanduser(d)) for d in args.dirs]
    else:
        base = Path.home() / '.codex'
        dirs = [d for d in (base / 'sessions', base / 'archived_sessions') if d.is_dir()]
    if not dirs:
        sys.exit('找不到会话目录。用 --dirs 指定，例如 --dirs ~/.codex/sessions')

    files = []
    for d in dirs:
        if not d.is_dir():
            print(f'跳过（不存在）：{d}')
            continue
        files += sorted(d.rglob('*.jsonl'), key=lambda p: p.stat().st_mtime)
    files = [f for f in files if f.stat().st_size >= args.min_mb * 1048576]
    if not files:
        sys.exit('没找到 .jsonl 会话文件。')

    total_mb = sum(f.stat().st_size for f in files) / 1048576
    print(f'找到 {len(files)} 个会话文件，合计 {total_mb:.1f} MB\n')

    if args.probe:
        probe(files)
        print('结构看清楚了就去掉 --probe 正式生成。若上面 role/type 全是 None，把这段输出发我，我调整解析。')
        return

    out = Path(os.path.expanduser(args.out))
    (out / 'sessions').mkdir(parents=True, exist_ok=True)

    digests = []
    for i, f in enumerate(files, 1):
        d = Digest(f)
        try:
            with f.open(encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    if line.strip():
                        d.feed(line)
        except Exception as e:
            print(f'  ! 读取失败 {f.name}: {e}')
            continue
        md = d.to_markdown()
        (out / 'sessions' / (f.stem[:120] + '.md')).write_text(md, encoding='utf-8')
        digests.append(d)
        print(f'[{i}/{len(files)}] {f.name[:60]:62s} {d.size/1048576:7.1f} MB → {len(md)/1024:6.1f} KB')

    # 总览
    idx = ['# Codex 项目经验包', '',
           f'生成时间：{datetime.now():%Y-%m-%d %H:%M}',
           f'来源：{len(digests)} 个会话，原始 {total_mb:.1f} MB', '']
    kept = sum(len(d.to_markdown()) for d in digests)
    idx += [f'提炼后：{kept/1024:.1f} KB（压缩比约 {total_mb*1048576/max(kept,1):.0f} : 1）', '',
            '> 下面每一节对应一个会话。可整份或按节复制进新对话窗口作为上下文。', '', '---', '']
    for d in sorted(digests, key=lambda x: x.mtime, reverse=True):
        idx.append(d.to_markdown())
        idx.append('\n---\n')
    (out / '经验包总览.md').write_text('\n'.join(idx), encoding='utf-8')

    print(f'\n原始 {total_mb:.1f} MB → 提炼 {kept/1024:.1f} KB'
          f'（压缩比约 {total_mb*1048576/max(kept,1):.0f} : 1）')
    print(f'总览：{out / "经验包总览.md"}')
    print(f'单个会话：{out / "sessions"}/')
    print('\n原始文件一个都没动。确认经验包内容满意后，再自行决定是否删除原始 .jsonl。')


if __name__ == '__main__':
    main()
