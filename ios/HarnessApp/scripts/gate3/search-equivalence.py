#!/usr/bin/env python3
"""Gate 3 (#39): native glob/grep against the packaged ripgrep, over one fixture matrix.

Both sides get the exact argv dsh-tool-fs-search builds. Glob output must match byte for
byte (modification order is made unambiguous); grep compares the parsed match records the
official parser keeps, as a set, because rg's file order is unspecified. Failures compare by
the class the official tool derives from stderr. Writes a redacted summary next to the
private evidence and exits nonzero on any difference.
"""
import argparse, json, os, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
PACKAGE = HERE.parents[2]
REPO = HERE.parents[4]
DEFAULT_RG = REPO / "build/prototypes/plan500-worker/harness-dependencies/node_modules/@vscode/ripgrep-darwin-arm64/bin/rg"
VCS = [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"]


def write(root, path, data, mtime):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data if isinstance(data, bytes) else data.encode())
    os.utime(target, (mtime, mtime))


def fixture(root):
    """Returns the workspace path; every file gets a distinct modification time."""
    files = [
        ("README.md", "# 演示\nfoo bar\nTODO: 写测试\n"),
        ("src/main.ts", "import x from './x'\nconst foo = 1\n// TODO later\n"),
        ("src/util/helpers.ts", "export function foo() {}\nexport const BAR = 2\n"),
        ("src/util/helpers.test.ts", "test('foo', () => {})\n"),
        ("src/子目录/说明.md", "第一行 foo\n第二行\n汉字 TODO\n"),
        ("src/crlf.txt", b"foo\r\nbar\r\nfoo end\r\n"),
        ("src/no-newline.txt", "last foo"),
        ("src/empty.txt", ""),
        ("src/bom8.txt", b"\xef\xbb\xbffoo with bom\n"),
        ("src/bom16.txt", "﻿foo utf16\nsecond\n".encode("utf-16-le")),
        ("src/invalid.txt", b"foo \xff\xfe bytes\nplain foo\n"),
        ("src/binary.bin", b"foo\x00bar\nfoo again\n"),
        ("src/late-binary.dat", b"foo first\n" + b"x" * 100 + b"\x00\nfoo after\n"),
        ("build/out.js", "foo built\n"),
        ("dist/bundle.js", "foo bundle\n"),
        ("logs/app.log", "foo log\n"),
        ("logs/keep.log", "foo keep\n"),
        ("notes.tmp", "foo tmp\n"),
        (".env", "FOO=1\n"),
        (".config/settings.json", "{\"foo\": true}\n"),
        ("docs/guide.md", "foo guide\n"),
        ("docs/private/secret.md", "foo secret\n"),
        ("vendor/lib/lib.ts", "foo vendor\n"),
        ("nested/.gitignore", "*.gen\n!keep.gen\n"),
        ("nested/a.gen", "foo gen\n"),
        ("nested/keep.gen", "foo keep gen\n"),
        ("nested/deep/b.gen", "foo deep gen\n"),
        ("nested/repo/.gitignore", "inner.txt\n"),
        ("nested/repo/inner.txt", "foo inner\n"),
        ("nested/repo/x.gen", "foo repo gen\n"),
        ("ign/.ignore", "*.ign\n"),
        ("ign/a.ign", "foo ign\n"),
        ("ign/.rgignore", "!a.ign\n"),
        ("ign/b.ign", "foo ign b\n"),
        ("anchored/root.txt", "foo root\n"),
        ("anchored/sub/root.txt", "foo sub root\n"),
        ("weird name [1].txt", "foo weird\n"),
        ("dash-file.txt", "-foo\n"),
        ("regex.txt", "aaa\nfoo bar\nFOO\nA1\n汉字 x\n\ta{b\n{,3}\nword boundary\nvalue=42\n"),
        (".git/HEAD", "ref: refs/heads/main\n"),
        (".git/info/exclude", "*.excluded\n"),
        ("thing.excluded", "foo excluded\n"),
        (".svn/entries", "foo svn\n"),
        (".hg/store", "foo hg\n"),
        ("nested/repo/.git/HEAD", "ref: refs/heads/main\n"),
    ]
    ws = root / "workspace"
    base = 1_700_000_000
    for index, (path, data) in enumerate(files):
        write(ws, path, data, base + index * 7)
    write(ws, ".gitignore", "build/\n/dist\n*.log\n!keep.log\n*.tmp\ndocs/private/\n/anchored/root.txt\n", base - 1)
    os.symlink("src/main.ts", ws / "link-main.ts")
    os.symlink("src", ws / "link-src")
    os.symlink("../outside", ws / "escape")
    os.mkfifo(ws / "pipe.ts")
    (root / "outside").mkdir()
    (root / "outside/secret.txt").write_text("foo outside\n")
    return ws


def nongit_fixture(root):
    ws = root / "plain"
    write(ws, ".gitignore", "ignored.txt\n", 1_700_000_000)
    write(ws, "ignored.txt", "foo ignored but no repo\n", 1_700_000_001)
    write(ws, ".ignore", "skipped.txt\n", 1_700_000_002)
    write(ws, "skipped.txt", "foo skipped\n", 1_700_000_003)
    write(ws, "kept.txt", "foo kept\n", 1_700_000_004)
    return ws


def run(argv, cwd):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
    return result.returncode, result.stdout, result.stderr.decode("utf-8", "replace")


def failure_class(code, stderr):
    if code in (0, 1):
        return None
    if "regex parse error" in stderr or "error parsing glob" in stderr:
        return "SEARCH_INVALID_PATTERN"
    return "SEARCH_FAILED"


def grep_records(stdout):
    records = []
    for line in stdout.decode("utf-8").split("\n"):
        if not line:
            continue
        record = json.loads(line)
        if record["type"] != "match":
            continue
        data = record["data"]
        lines = data["lines"]
        text = lines["text"] if "text" in lines else "(line is not valid UTF-8)"
        records.append((data["path"].get("text"), data["line_number"], text.rstrip("\n").removesuffix("\r")))
    return sorted(records)


def glob_argv(pattern, path=None):
    argv = ["--files", f"--glob={pattern}", "--sort=modified", "--no-ignore", "--hidden"]
    for name in VCS:
        argv += [f"--glob=!**/{name}", f"--glob=!**/{name}/**"]
    return argv + (["--", path] if path is not None else [])


def grep_argv(pattern, include=None, path=None):
    argv = ["--json", f"--regexp={pattern}"]
    if include is not None:
        argv.append(f"--glob={include}")
    return argv + (["--", path] if path is not None else [])


GLOBS = [
    ("*.ts", None), ("**/*.ts", None), ("src/*.ts", None), ("src/**/*.ts", None), ("*.{ts,md}", None),
    ("**/*.test.ts", None), ("*.md", "src"), ("*.md", "./src"), ("*.md", "src/"), ("*", "docs"),
    ("**/*", "nested"), ("*.log", None), (".env", None), ("**/.config/*", None), ("[ab]*.gen", "nested"),
    ("[!a]*.gen", "nested"), ("*.ts", "link-src"), ("*.ts", "link-main.ts"), ("*.zzz", None),
    ("*.ts", "missing-dir"), ("{a", None), ("[", None), ("src/**", None), ("**/子目录/*", None),
    ("weird name ?1?.txt", None), ("*.txt", "."), ("*.ts", "escape"), ("**/sub/**", None), ("*", "src/util/"),
]

PATTERNS = [
    "foo", "TODO", "汉字", "^foo", "foo$", "(?i)foo", r"\bfoo\b", r"\d+", r"[[:alpha:]]+", "a{2}", "a{,3}",
    "a{", r"foo(?=x)", r"\1", r"(?P<n>foo)", r"(?<n>foo)", r"\Qa\E", r"\<foo", r"a*+", "a++", r"\p{Han}+",
    r"\x{6c49}", "[a-z&&[^b]]", r"[^]a]", "(?U)a+", r"(?x) f o o", "a\nb", r"\n", "foo|bar", r"\.", "-foo",
    r"[\d]", r"\w+=\d+", "(unclosed", "x)", "*foo", r"\z", "(?s).", r"\x41", r"\e", "(?>a)",
]

GREPS = [(p, None, None) for p in PATTERNS] + [
    ("foo", "*.ts", None), ("foo", "*.log", None), ("foo", "*.md", "src"), ("foo", None, "src/binary.bin"),
    ("foo", None, "src/late-binary.dat"), ("foo", None, "link-main.ts"), ("foo", None, "link-src"),
    ("foo", None, "build"), ("foo", None, "docs/private/secret.md"), ("foo", None, "missing"),
    ("foo", None, "."), ("foo", None, "./nested"), ("foo", "{a,b", None), ("foo", "**/*.gen", None),
    ("foo", ".env", None), ("foo", None, "escape"), ("foo", None, "nested/repo"), ("foo", None, "ign"),
]

# Differences ADR 0003 declares instead of emulating; each still has to fail closed.
DECLARED = {
    ("glob", "*.ts", "escape"): "a symlink out of the workspace is refused, never followed",
    ("grep", "foo", None, "escape"): "a symlink out of the workspace is refused, never followed",
    ("grep", "(?U)a+", None, None): "the U flag is refused instead of swapping greediness",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rg", default=str(DEFAULT_RG))
    parser.add_argument("--summary", default=str(REPO / "build/issue39-gate3/search-equivalence-safe.json"))
    options = parser.parse_args()
    subprocess.run(["swift", "build", "--product", "native-tools-probe"], cwd=PACKAGE, check=True, capture_output=True)
    probe = str(PACKAGE / ".build/debug/native-tools-probe")
    rg = [options.rg, "--no-config"]
    version = run([options.rg, "--version"], "/")[1].decode().split("\n")[0]
    results, failures = [], []
    with tempfile.TemporaryDirectory(prefix="gate3-search-") as temp:
        root = Path(temp).resolve()
        cases = []
        ws = fixture(root)
        cases += [("glob", ws, glob_argv(pattern, path), (pattern, path)) for pattern, path in GLOBS]
        cases += [("grep", ws, grep_argv(p, include, path), (p, include, path)) for p, include, path in GREPS]
        plain = nongit_fixture(root)
        cases += [("grep", plain, grep_argv("foo"), ("foo", None, "<no repo>")), ("glob", plain, glob_argv("*"), ("*", "<no repo>"))]
        for kind, cwd, argv, key in cases:
            expected = run(rg + argv, cwd)
            actual = run([probe, "rg", str(cwd), str(cwd), "--no-config"] + argv, cwd)
            declared = DECLARED.get((kind,) + key)
            if kind == "glob":
                same = expected[0] == actual[0] and expected[1] == actual[1] if expected[0] in (0, 1) else \
                    failure_class(*expected[::2]) == failure_class(*actual[::2])
            else:
                same = (failure_class(expected[0], expected[2]) == failure_class(actual[0], actual[2]) and
                        (expected[0] not in (0, 1) or (expected[0] == actual[0] and grep_records(expected[1]) == grep_records(actual[1]))))
            if declared:
                # A declared case must still end as a search failure or an empty result, never data.
                same = actual[0] == 2 or (actual[0] == 1 and not actual[1])
            entry = {"kind": kind, "case": [str(part) for part in key], "rgExit": expected[0], "nativeExit": actual[0],
                     "equal": same, **({"declared": declared} if declared else {})}
            results.append(entry)
            if not same:
                failures.append(entry)
                print(f"DIFF {kind} {key}\n  rg     {expected[0]} {expected[1][:400]!r} {expected[2][:200]!r}\n"
                      f"  native {actual[0]} {actual[1][:400]!r} {actual[2][:200]!r}")
    summary = {"ripgrep": version, "cases": len(results), "differences": len(failures),
               "declared": sorted(set(DECLARED.values())), "results": results}
    Path(options.summary).parent.mkdir(parents=True, exist_ok=True)
    Path(options.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(f"SEARCH_EQUIVALENCE cases={len(results)} differences={len(failures)} rg={version}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
