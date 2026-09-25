import re

def demangle(m):
    if not m or m[0] != 'N':
        return m
    s = m[1:]
    if s.endswith('E'):
        s = s[:-1]
    comps = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == 'E':
            break
        if c == 'S':
            m2 = re.match(r'S(\d+)_', s[i:])
            if not m2:
                i += 1
                continue
            i += m2.end()
            comps.append(f'<sub{m2.group(1)}>')
            continue
        if c == 'I':
            # template argument list: read to matching E
            depth = 0
            j = i
            while j < n:
                if s[j] == 'I':
                    depth += 1
                elif s[j] == 'E':
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            arg = s[i + 1:j - 1]
            arg = re.sub(r'NSt3__(\d+)', lambda mm: 'std::' if False else 'std::__1', arg)
            comps[-1] = comps[-1] + '<' + arg + '>' if comps else arg
            i = j
            continue
        if c == 'L' or c == 'K' or c == 'V' or c == 'r' or c == 'R' or c == 'O':
            # builtin type prefixes
            m2 = re.match(r'L(?:i|f|d|x|s|n|b|j|m|x)\w?', s[i:])
            if m2:
                comps.append(('i' if m2.group(0) == 'Li' else 'j' if m2.group(0) == 'Lj' else 'f' if m2.group(0) == 'Lf' else 'd' if m2.group(0) == 'Ld' else 'b' if m2.group(0) == 'Lb' else 'm' if m2.group(0) == 'Lm' else 'x'))
                i += m2.end()
                continue
            i += 1
            continue
        m2 = re.match(r'\d+', s[i:])
        if m2:
            ln = int(m2.group(0))
            st = i + m2.end()
            comps.append(s[st:st + ln])
            i = st + ln
            continue
        m2 = re.match(r'[A-Za-z_][A-Za-z0-9_]*', s[i:])
        if m2:
            comps.append(m2.group(0))
            i += m2.end()
            continue
        i += 1
    return '::'.join(c for c in comps if c)

if __name__ == '__main__':
    import sys
    for l in sys.stdin:
        l = l.strip()
        if l:
            print(demangle(l))
