#!/usr/bin/env python3
"""Sim-only rewrite of (System)Verilog files that use signals before declaring them.

Quartus accepts a module-level net/variable being referenced before its declaration; strict
SystemVerilog (Questa) does not. For each module this moves module-level declarations of the
built-in types (reg/wire/logic/bit/integer/int) to just after the module header. Declarations
with an initializer on a net ('wire x = expr;') become a hoisted 'wire x;' plus an
'assign x = expr;' left in place; variable initializers ('reg x = 0;') stay with the hoisted
declaration only when the value is a plain literal, otherwise they are split the same way
(as 'initial'-free continuous assigns are not legal for variables, those are left in place).

Only depth-0 statements are touched: anything inside begin/end, case, function, task, generate,
fork or fixed-bound constructs is left alone. The output is used for simulation only and is
never synthesized.

Usage: hoist_decls.py <in> <out>
"""
import re
import sys

OPEN = {'begin', 'case', 'casex', 'casez', 'function', 'task', 'generate', 'fork', 'module',
        'interface', 'package', 'class', 'covergroup', 'specify'}
CLOSE = {'end', 'endcase', 'endfunction', 'endtask', 'endgenerate', 'join', 'join_any',
         'join_none', 'endmodule', 'endinterface', 'endpackage', 'endclass', 'endgroup',
         'endspecify'}
ATTR = r'(?:\(\*.*?\*\)\s*)?'
DECL = re.compile(r'^\s*' + ATTR + r'(reg|wire|logic|bit|integer|int)\b')
PORT = re.compile(r'^\s*(input|output|inout)\b')
PARAM = re.compile(r'^\s*(localparam|parameter)\b')
LITERAL = re.compile(r"^\s*(['\d][\w'.]*|'[01xzXZ]|\{[^{}]*\})\s*$")


def strip_comments(text):
    """Return text with comments and strings replaced by spaces (same length)."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            for k in range(i, min(j + 1, n)):
                out[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(out)


def split_top(s):
    """Split on commas that are not inside (), [] or {}."""
    parts, depth, cur = [], 0, ''
    for ch in s:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    parts.append(cur)
    return parts


def rewrite(text):
    clean = strip_comments(text)
    result = []
    pos = 0
    for m in re.finditer(r'\bmodule\b', clean):
        mstart = m.start()
        # header ends at the first ');' followed by ... or ';' after the port list
        hdr_end = clean.find(';', mstart)
        # skip over the parenthesised port list if present
        paren = clean.find('(', mstart)
        if paren != -1 and paren < hdr_end or (paren != -1 and clean[mstart:paren].count('#')):
            depth = 0
            k = paren
            # handle #( params ) ( ports )
            while True:
                while k < len(clean):
                    if clean[k] == '(':
                        depth += 1
                    elif clean[k] == ')':
                        depth -= 1
                        if depth == 0:
                            break
                    k += 1
                nxt = re.match(r'\s*\(', clean[k + 1:])
                if nxt:
                    k = k + 1 + nxt.end() - 1
                    continue
                break
            hdr_end = clean.find(';', k)
        mend = re.compile(r'\bendmodule\b').search(clean, hdr_end)
        if not mend:
            continue
        body_start, body_end = hdr_end + 1, mend.start()
        body, cbody = text[body_start:body_end], clean[body_start:body_end]

        hoisted, new_body, ports, params = [], [], [], []
        local_inits = []
        depth = 0
        stmt_start = 0
        i = 0
        tokens = re.finditer(r"\b[A-Za-z_]\w*\b|;", cbody)
        for t in tokens:
            tok = t.group(0)
            if tok in OPEN:
                depth += 1
            elif tok in CLOSE:
                depth -= 1
                if depth == 0:
                    stmt_start = t.end()
            elif tok == ';':
                if depth > 0:
                    # Block-local variable without an initializer (e.g. reg [1:0] cnt; inside an
                    # always block): initialize to 0 like FPGA power-up. Static, so this happens
                    # once at time 0. Skipped for arrays, automatic variables and nets.
                    sstart = max(cbody.rfind(';', 0, t.start()), cbody.rfind('\n', 0, t.start()))
                    line_c = cbody[sstart + 1:t.end()]
                    mloc = re.match(r'^\s*(?:begin\b.*?)?\s*(reg|bit|logic)\b([^=;()]*);\s*$', line_c)
                    if mloc and 'automatic' not in line_c and not re.search(r'\w\s*\[', mloc.group(2).strip()):
                        names = mloc.group(2)
                        # 'reg [1:0] a, b' -> 'reg [1:0] a = 0, b = 0'
                        lead_rng = re.match(r'\s*((?:signed\s*)?(?:\[[^\]]*\]\s*)*)', names)
                        rng = lead_rng.group(1)
                        ids = [x.strip() for x in names[lead_rng.end():].split(',') if x.strip()]
                        if ids and all(re.fullmatch(r'\w+', x) for x in ids):
                            new_decl = mloc.group(1) + ' ' + rng + ', '.join(f'{x} = 0' for x in ids) + ';'
                            abs_start = sstart + 1 + line_c.index(mloc.group(1))
                            local_inits.append((abs_start, t.end(), new_decl))
                if depth == 0:
                    stmt = body[stmt_start:t.end()]
                    cstmt = cbody[stmt_start:t.end()]
                    new_body.append(body[i:stmt_start])
                    # Attributes like (* direct_enable = 1 *) are irrelevant in simulation and
                    # their '=' would look like an initializer: classify without them.
                    stmt = re.sub(r'\(\*.*?\*\)', '', stmt)
                    cstmt = re.sub(r'\(\*.*?\*\)', '', cstmt)
                    m2 = DECL.match(cstmt)
                    lead = stmt[:len(stmt) - len(stmt.lstrip())]
                    if PARAM.match(cstmt):
                        params.append(stmt.strip())
                        new_body.append(lead)
                    elif PORT.match(cstmt):
                        ports.append(stmt.strip())
                        new_body.append(lead)
                    elif m2 and '(' not in re.sub(r'\(\*.*?\*\)', '', cstmt).split('=')[0]:
                        kind = m2.group(1)
                        decl, eq, init = cstmt.partition('=')
                        if not eq:
                            hoisted.append(stmt.strip())
                            new_body.append(lead)
                        else:
                            # declarator list: 'type name = v, name2 = v2' -> literal inits only
                            items = [x.strip() for x in split_top(stmt.strip().rstrip(';'))]
                            head = items[0]
                            if kind == 'wire' and len(items) == 1:
                                d, _, v = head.partition('=')
                                hoisted.append(d.strip() + ';')
                                name = re.findall(r'(\w+)\s*(?:\[[^\]]*\]\s*)*$', d.strip())[0]
                                new_body.append(f"{lead}assign {name} = {v.strip()};")
                            elif all(LITERAL.match(x.partition('=')[2]) for x in items if '=' in x):
                                hoisted.append(stmt.strip())
                                new_body.append(lead)
                            else:
                                new_body.append(stmt)
                    else:
                        new_body.append(stmt)
                    i = t.end()
                    stmt_start = t.end()
        new_body.append(body[i:])
        body_out = ''.join(new_body)
        # Apply block-local initializers (they sit inside nested blocks, which the depth-0 pass
        # copied verbatim, so the same text is present in body_out).
        for st, en, new in sorted(local_inits, reverse=True):
            old = body[st:en]
            body_out = body_out.replace(old, new, 1) if old in body_out else body_out
        new_body = [body_out]
        result.append(text[pos:body_start])
        if hoisted or ports or params:
            result.append('\n// ---- hoisted declarations (sim only) ----\n' + '\n'.join(params + ports + hoisted) + '\n')
        result.append(''.join(new_body))
        pos = body_end
    result.append(text[pos:])
    return ''.join(result)


def type_outputs(text):
    """'output [..] x' without a type -> 'output logic [..] x'. Quartus lets an untyped output
    be assigned in an always block; SystemVerilog 'logic' accepts either one procedural or one
    continuous driver, so this is safe for both uses."""
    # (?=[\w\[]) makes \s+ consume all whitespace, so the type check sees the next token.
    # Only when 'output' is followed by a range or directly by the port name (an identifier then
    # ',', ';', ')' or '['); 'output some_type name' already has a type.
    return re.sub(r'\boutput(\s+)(?=\[|(?!(?:reg|wire|logic|bit|var|tri|wor|wand|integer|int|signed|unsigned)\b)\w+\s*[,;)\[])',
                  r'output\1logic ', text)


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, newline='', errors='replace').read().replace('\r\n', '\n')
    # vlog -E wraps its output in `begin_keywords/`end_keywords; drop them (they break when the
    # rewritten files are compiled together).
    text = re.sub(r'^\s*`(begin|end)_keywords.*$', '', text, flags=re.M)
    open(dst, 'w').write(rewrite(type_outputs(text)))
