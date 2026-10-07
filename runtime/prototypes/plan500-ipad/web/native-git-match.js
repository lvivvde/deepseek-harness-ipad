/*
 * Path patterns for the native read-only Git of deepseek-harness-ipad:
 * wildmatch, .gitignore lists, and .gitattributes lines, as git v2.54.0
 * evaluates them (wildmatch.c, dir.c, attr.c, quote.c).
 *
 * Copyright (C) the Git project contributors. This port is distributed under
 * the GNU General Public License version 2, as git is.
 *
 * Patterns and paths are byte strings, one character per byte. Case folding
 * (core.ignorecase) is not supported; callers refuse such repositories.
 */
(function (root) {
	"use strict";

	const MATCH = 0, NOMATCH = 1, ABORT_ALL = -1, ABORT_TO_STARSTAR = -2;
	const WM_PATHNAME = 2;
	const SLASH = 0x2f, STAR = 0x2a, BACKSLASH = 0x5c, QUESTION = 0x3f, BRACKET = 0x5b, CLOSE = 0x5d;

	const isUpper = (c) => c >= 0x41 && c <= 0x5a;
	const isLower = (c) => c >= 0x61 && c <= 0x7a;
	const isDigit = (c) => c >= 0x30 && c <= 0x39;
	const isAlpha = (c) => isUpper(c) || isLower(c);
	const isSpace = (c) => c === 9 || c === 10 || c === 13 || c === 32;
	const isPrint = (c) => c >= 0x20 && c <= 0x7e;
	const isGlobSpecial = (c) => c === STAR || c === QUESTION || c === BRACKET || c === BACKSLASH;
	const CLASSES = {
		alnum: (c) => isAlpha(c) || isDigit(c),
		alpha: isAlpha,
		blank: (c) => c === 32 || c === 9,
		cntrl: (c) => c < 32 || c === 127,
		digit: isDigit,
		graph: (c) => c >= 0x21 && c <= 0x7e,
		lower: isLower,
		print: isPrint,
		punct: (c) => (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126),
		space: isSpace,
		upper: isUpper,
		xdigit: (c) => isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66),
	};

	/** The byte at `i`, or 0 past the end, as a C string reads. */
	function at(s, i) {
		return i < s.length ? s.charCodeAt(i) : 0;
	}

	function dowild(pat, p, text, t, flags) {
		const start = p;
		let pCh;
		for (; (pCh = at(pat, p)) !== 0; t++, p++) {
			let matched, matchSlash;
			let tCh = at(text, t);
			if (tCh === 0 && pCh !== STAR) return ABORT_ALL;
			switch (pCh) {
				case BACKSLASH:
					pCh = at(pat, ++p);
				// falls through
				default:
					if (tCh !== pCh) return NOMATCH;
					continue;
				case QUESTION:
					if ((flags & WM_PATHNAME) && tCh === SLASH) return NOMATCH;
					continue;
				case STAR: {
					if (at(pat, ++p) === STAR) {
						const prevP = p;
						while (at(pat, ++p) === STAR) { /* skip */ }
						if (!(flags & WM_PATHNAME)) matchSlash = 1;
						else if ((prevP - start < 2 || at(pat, prevP - 2) === SLASH) &&
							(at(pat, p) === 0 || at(pat, p) === SLASH || (at(pat, p) === BACKSLASH && at(pat, p + 1) === SLASH))) {
							if (at(pat, p) === SLASH && dowild(pat, p + 1, text, t, flags) === MATCH) return MATCH;
							matchSlash = 1;
						} else matchSlash = 0;
					} else matchSlash = flags & WM_PATHNAME ? 0 : 1;
					if (at(pat, p) === 0) {
						if (!matchSlash && text.indexOf("/", t) >= 0) return ABORT_TO_STARSTAR;
						return MATCH;
					} else if (!matchSlash && at(pat, p) === SLASH) {
						const slash = text.indexOf("/", t);
						if (slash < 0) return ABORT_ALL;
						t = slash;
						break;
					}
					for (;;) {
						if (tCh === 0) break;
						if (!isGlobSpecial(at(pat, p))) {
							pCh = at(pat, p);
							while ((tCh = at(text, t)) !== 0 && (matchSlash || tCh !== SLASH)) {
								if (tCh === pCh) break;
								t++;
							}
							if (tCh !== pCh) return matchSlash ? ABORT_ALL : ABORT_TO_STARSTAR;
						}
						if ((matched = dowild(pat, p, text, t, flags)) !== NOMATCH) {
							if (!matchSlash || matched !== ABORT_TO_STARSTAR) return matched;
						} else if (!matchSlash && tCh === SLASH) return ABORT_TO_STARSTAR;
						tCh = at(text, ++t);
					}
					return ABORT_ALL;
				}
				case BRACKET: {
					pCh = at(pat, ++p);
					if (pCh === 0x5e) pCh = 0x21;
					const negated = pCh === 0x21 ? 1 : 0;
					if (negated) pCh = at(pat, ++p);
					let prevCh = 0;
					matched = 0;
					do {
						if (!pCh) return ABORT_ALL;
						if (pCh === BACKSLASH) {
							pCh = at(pat, ++p);
							if (!pCh) return ABORT_ALL;
							if (tCh === pCh) matched = 1;
						} else if (pCh === 0x2d && prevCh && at(pat, p + 1) && at(pat, p + 1) !== CLOSE) {
							pCh = at(pat, ++p);
							if (pCh === BACKSLASH) {
								pCh = at(pat, ++p);
								if (!pCh) return ABORT_ALL;
							}
							if (tCh <= pCh && tCh >= prevCh) matched = 1;
							pCh = 0;
						} else if (pCh === BRACKET && at(pat, p + 1) === 0x3a) {
							p += 2;
							const s = p;
							for (; (pCh = at(pat, p)) && pCh !== CLOSE; p++) { /* find ']' */ }
							if (!pCh) return ABORT_ALL;
							const i = p - s - 1;
							if (i < 0 || at(pat, p - 1) !== 0x3a) {
								p = s - 2;
								pCh = BRACKET;
								if (tCh === pCh) matched = 1;
							} else {
								const test = Object.prototype.hasOwnProperty.call(CLASSES, pat.slice(s, s + i)) ? CLASSES[pat.slice(s, s + i)] : null;
								if (!test) return ABORT_ALL;
								if (test(tCh)) matched = 1;
								pCh = 0;
							}
						} else if (tCh === pCh) matched = 1;
						prevCh = pCh;
						pCh = at(pat, ++p);
					} while (pCh !== CLOSE);
					if (matched === negated || ((flags & WM_PATHNAME) && tCh === SLASH)) return NOMATCH;
					continue;
				}
			}
		}
		return t < text.length ? NOMATCH : MATCH;
	}

	/**
	 * git's wildmatch without case folding.
	 * @param {string} pattern - glob, byte string.
	 * @param {string} text - candidate, byte string.
	 * @param {number} flags - WM_PATHNAME or 0.
	 * @returns {boolean}
	 */
	function wildmatch(pattern, text, flags) {
		const nul = pattern.indexOf("\0");
		if (nul >= 0) pattern = pattern.slice(0, nul);
		return dowild(pattern, 0, text, 0, flags) === MATCH;
	}

	const FLAG_NODIR = 1, FLAG_ENDSWITH = 4, FLAG_MUSTBEDIR = 8, FLAG_NEGATIVE = 16;

	/** Length of the leading part of a pattern without glob characters. */
	function simpleLength(s) {
		let i = 0;
		while (i < s.length && !isGlobSpecial(s.charCodeAt(i))) i++;
		return i;
	}

	/**
	 * Split one pattern line into its pattern and flags (dir.c parse_path_pattern).
	 * @param {string} line - pattern text.
	 * @returns {{pattern: string, flags: number, prefix: number}}
	 */
	function parsePattern(line) {
		let p = line, flags = 0;
		if (p.charCodeAt(0) === 0x21) {
			flags |= FLAG_NEGATIVE;
			p = p.slice(1);
		}
		let len = p.length;
		if (len && p.charCodeAt(len - 1) === SLASH) {
			len--;
			flags |= FLAG_MUSTBEDIR;
		}
		if (p.slice(0, len).indexOf("/") < 0) flags |= FLAG_NODIR;
		const prefix = Math.min(simpleLength(p), len);
		if (p.charCodeAt(0) === STAR && simpleLength(p.slice(1)) === p.length - 1) flags |= FLAG_ENDSWITH;
		return { pattern: p.slice(0, len), flags, prefix };
	}

	/** dir.c match_basename. */
	function matchBasename(basename, pat) {
		const { pattern, prefix } = pat;
		if (prefix === pattern.length) return basename === pattern;
		if (pat.flags & FLAG_ENDSWITH) return pattern.length - 1 <= basename.length && basename.endsWith(pattern.slice(1));
		return wildmatch(pattern, basename, 0);
	}

	/** dir.c match_pathname; `baselen` excludes the base's trailing slash. */
	function matchPathname(pathname, base, baselen, pat) {
		let pattern = pat.pattern, prefix = pat.prefix;
		if (pattern.charCodeAt(0) === SLASH) {
			pattern = pattern.slice(1);
			prefix--;
		}
		if (pathname.length < baselen + 1 || (baselen && pathname.charCodeAt(baselen) !== SLASH) ||
			pathname.slice(0, baselen) !== base.slice(0, baselen)) return false;
		const namelen = baselen ? pathname.length - baselen - 1 : pathname.length;
		let name = pathname.slice(pathname.length - namelen);
		if (prefix) {
			if (prefix > namelen) return false;
			if (pattern.slice(0, prefix) !== name.slice(0, prefix)) return false;
			if (pattern.length === prefix && namelen === prefix) return true;
			prefix--;
			pattern = pattern.slice(prefix);
			name = name.slice(prefix);
		}
		return wildmatch(pattern, name, WM_PATHNAME);
	}

	/** dir.c trim_trailing_spaces. */
	function trimTrailingSpaces(s) {
		let lastSpace = -1;
		for (let i = 0; i < s.length; i++) {
			const c = s.charCodeAt(i);
			if (c === 0x20) {
				if (lastSpace < 0) lastSpace = i;
			} else if (c === BACKSLASH) {
				i++;
				if (i >= s.length) return s;
				lastSpace = -1;
			} else lastSpace = -1;
		}
		return lastSpace >= 0 ? s.slice(0, lastSpace) : s;
	}

	/**
	 * Ignore patterns from one file's bytes (dir.c add_patterns_from_buffer).
	 * @param {string} buf - file bytes with git's appended newline.
	 * @param {string} base - directory of the file with a trailing slash, or "".
	 * @returns {{patterns: object[], base: string}}
	 */
	function excludeList(buf, base) {
		if (buf.startsWith("\xef\xbb\xbf")) buf = buf.slice(3);
		const patterns = [];
		let entry = 0;
		for (let i = 0; i < buf.length; i++) {
			if (buf.charCodeAt(i) !== 10) continue;
			if (entry !== i && buf.charCodeAt(entry) !== 0x23) {
				let line = buf.slice(entry, i && buf.charCodeAt(i - 1) === 13 ? i - 1 : i);
				const nul = line.indexOf("\0");
				if (nul >= 0) line = line.slice(0, nul);
				patterns.push(parsePattern(trimTrailingSpaces(line)));
			}
			entry = i + 1;
		}
		return { patterns, base };
	}

	const DT_UNKNOWN = 0, DT_DIR = 4, DT_REG = 8, DT_LNK = 10;

	/**
	 * The last pattern of one list that matches (dir.c last_matching_pattern_from_list).
	 * @param {string} pathname - path relative to the work tree.
	 * @param {string} basename - its last component.
	 * @param {number} dtype - DT_* type of the path.
	 * @param {{patterns: object[], base: string}} list - pattern list.
	 * @returns {object | null}
	 */
	function lastMatching(pathname, basename, dtype, list) {
		const baselen = list.base.length;
		for (let i = list.patterns.length - 1; i >= 0; i--) {
			const pat = list.patterns[i];
			if ((pat.flags & FLAG_MUSTBEDIR) && dtype !== DT_DIR) continue;
			if (pat.flags & FLAG_NODIR) {
				if (matchBasename(basename, pat)) return pat;
				continue;
			}
			if (matchPathname(pathname, list.base, baselen ? baselen - 1 : 0, pat)) return pat;
		}
		return null;
	}

	/**
	 * Ignore rules of one work tree, loaded directory by directory the way
	 * dir.c prep_exclude loads them.
	 */
	class Excludes {
		/**
		 * @param {(dir: string) => string | null} load - bytes of `<dir>/.gitignore` with the appended newline, or null.
		 * @param {{patterns: object[], base: string} | null} infoExclude - $GIT_DIR/info/exclude patterns.
		 */
		constructor(load, infoExclude) {
			this.load = load;
			this.info = infoExclude;
			this.dirs = new Map();
		}

		state(dir) {
			let state = this.dirs.get(dir);
			if (state) return state;
			if (dir === "") {
				const buf = this.load("");
				state = { lists: buf === null ? [] : [excludeList(buf, "")], excludedBy: null };
			} else {
				const slash = dir.lastIndexOf("/");
				const parent = this.state(slash < 0 ? "" : dir.slice(0, slash));
				if (parent.excludedBy) state = parent;
				else {
					const hit = this.fromLists(dir, dir.slice(slash + 1), DT_DIR, parent.lists);
					if (hit && !(hit.flags & FLAG_NEGATIVE)) state = { lists: parent.lists, excludedBy: hit };
					else {
						const buf = this.load(dir);
						state = { lists: buf === null ? parent.lists : parent.lists.concat([excludeList(buf, `${dir}/`)]), excludedBy: null };
					}
				}
			}
			this.dirs.set(dir, state);
			return state;
		}

		fromLists(pathname, basename, dtype, lists) {
			for (let i = lists.length - 1; i >= 0; i--) {
				const hit = lastMatching(pathname, basename, dtype, lists[i]);
				if (hit) return hit;
			}
			return this.info ? lastMatching(pathname, basename, dtype, this.info) : null;
		}

		/**
		 * The deciding pattern for a path (dir.c last_matching_pattern).
		 * @param {string} pathname - path relative to the work tree.
		 * @param {number} dtype - DT_* type, DT_UNKNOWN when it cannot be known.
		 * @returns {object | null}
		 */
		matching(pathname, dtype) {
			const slash = pathname.lastIndexOf("/");
			const state = this.state(slash < 0 ? "" : pathname.slice(0, slash));
			if (state.excludedBy) return state.excludedBy;
			return this.fromLists(pathname, pathname.slice(slash + 1), dtype, state.lists);
		}

		/** dir.c is_excluded. */
		excluded(pathname, dtype) {
			const hit = this.matching(pathname, dtype);
			return hit !== null && !(hit.flags & FLAG_NEGATIVE);
		}
	}

	const BLANK = " \t\r\n";
	const isBlank = (c) => c === 32 || c === 9 || c === 13 || c === 10;

	function span(s, i, inSet) {
		while (i < s.length && inSet(s.charCodeAt(i))) i++;
		return i;
	}

	/**
	 * quote.c unquote_c_style on a string starting with '"'.
	 * @returns {{value: string, end: number} | null}
	 */
	function unquoteC(s, start) {
		let i = start + 1, value = "";
		for (;;) {
			let j = i;
			while (j < s.length && s[j] !== "\"" && s[j] !== "\\") j++;
			value += s.slice(i, j);
			if (j >= s.length) return null;
			i = j + 1;
			if (s[j] === "\"") return { value, end: i };
			if (i >= s.length) return null;
			const ch = s[i++];
			const simple = { a: "\x07", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v", "\\": "\\", "\"": "\"" };
			if (Object.prototype.hasOwnProperty.call(simple, ch)) { value += simple[ch]; continue; }
			if (ch >= "0" && ch <= "3") {
				let code = (ch.charCodeAt(0) - 48) << 6;
				for (let k = 0; k < 2; k++) {
					const d = s[i++];
					if (!(d >= "0" && d <= "7")) return null;
					code |= (d.charCodeAt(0) - 48) << (3 * (1 - k));
				}
				value += String.fromCharCode(code);
				continue;
			}
			return null;
		}
	}

	function attrNameValid(name) {
		if (name.length === 0 || name[0] === "-") return false;
		return /^[-._0-9a-zA-Z]+$/.test(name);
	}

	/**
	 * One .gitattributes line (attr.c parse_attr_line).
	 * @param {string} line - line bytes, already without its newline.
	 * @param {boolean} macroOk - whether `[attr]` definitions are allowed here.
	 * @param {(message: string) => void} [warn] - receives git's stderr lines.
	 * @param {string} [src] - source name for diagnostics.
	 * @param {number} [lineno] - 1-based line number for diagnostics.
	 * @returns {object | null}
	 */
	function parseAttrLine(line, macroOk, warn = () => {}, src = "", lineno = 0) {
		const nul = line.indexOf("\0");
		if (nul >= 0) line = line.slice(0, nul);
		const first = span(line, 0, isBlank);
		if (first >= line.length || line[first] === "#") return null;
		if (line.length >= 2048) {
			warn(`warning: ignoring overly long attributes line ${lineno}\n`);
			return null;
		}
		let name, rest, restAt;
		const quoted = line[first] === "\"" ? unquoteC(line, first) : null;
		if (quoted) {
			name = quoted.value;
			rest = line;
			restAt = quoted.end;
		} else {
			let end = first;
			while (end < line.length && !isBlank(line.charCodeAt(end))) end++;
			name = line.slice(first, end);
			rest = line;
			restAt = end;
		}
		let isMacro = false;
		if (name.length > 6 && name.startsWith("[attr]")) {
			if (!macroOk) {
				warn(`${quoted ? name : line.slice(first)} not allowed: ${src}:${lineno}\n`);
				return null;
			}
			isMacro = true;
			let n = span(name, 6, isBlank);
			let e = n;
			while (e < name.length && !isBlank(name.charCodeAt(e))) e++;
			name = name.slice(n, e);
			if (!attrNameValid(name) || name.startsWith("builtin_")) {
				warn(`${name} is not a valid attribute name: ${src}:${lineno}\n`);
				return null;
			}
		}
		let cp = span(rest, restAt, isBlank);
		const states = [];
		while (cp < rest.length) {
			let ep = cp;
			while (ep < rest.length && !isBlank(rest.charCodeAt(ep))) ep++;
			let equals = rest.indexOf("=", cp);
			if (equals >= 0 && ep < equals) equals = -1;
			let nameStart = cp, value;
			const lead = rest[cp];
			if (lead === "-" || lead === "!") {
				nameStart++;
				value = lead === "-" ? false : null;
			} else value = equals < 0 ? true : rest.slice(equals + 1, ep);
			const attr = rest.slice(nameStart, equals >= 0 ? equals : ep);
			if (!attrNameValid(attr) || rest.slice(nameStart).startsWith("builtin_")) {
				warn(`${attr} is not a valid attribute name: ${src}:${lineno}\n`);
				return null;
			}
			states.push({ attr, value });
			cp = span(rest, ep, isBlank);
		}
		if (isMacro) return { isMacro, attr: name, states };
		const pat = parsePattern(name.indexOf("\0") >= 0 ? name.slice(0, name.indexOf("\0")) : name);
		if (pat.flags & FLAG_NEGATIVE) {
			warn("warning: Negative patterns are ignored in git attributes\nUse '\\!' for literal leading exclamation.\n");
			return null;
		}
		return { isMacro, pat, states };
	}

	/**
	 * A parsed .gitattributes source.
	 * @param {string[]} lines - its lines.
	 * @param {boolean} macroOk - whether macros are allowed.
	 * @param {(message: string) => void} [warn] - diagnostics.
	 * @param {string} [src] - source name for diagnostics.
	 * @returns {object[]}
	 */
	function attrFrame(lines, macroOk, warn, src = "") {
		const out = [];
		for (let i = 0; i < lines.length; i++) {
			const parsed = parseAttrLine(lines[i], macroOk, warn, src, i + 1);
			if (parsed) out.push(parsed);
		}
		return out;
	}

	/**
	 * Attribute values of one file path (attr.c collect_some_attrs).
	 * @param {string} path - file path relative to the work tree.
	 * @param {Array<{origin: string | null, lines: object[]}>} stack - frames from the top (info) down to builtin.
	 * @returns {Map<string, boolean | string | null>} every attribute the frames set; others are unset.
	 */
	function attrsOf(path, stack) {
		let lastSlash = -1;
		for (let i = 0; i < path.length; i++) if (path[i] === "/" && i + 1 < path.length) lastSlash = i;
		const basenameOffset = lastSlash + 1;
		const isdir = path.endsWith("/");
		const macros = new Map();
		for (const frame of stack) {
			for (let i = frame.lines.length - 1; i >= 0; i--) {
				const line = frame.lines[i];
				if (line.isMacro && !macros.has(line.attr)) macros.set(line.attr, line);
			}
		}
		const values = new Map();
		for (const frame of stack) {
			const base = frame.origin ?? "";
			for (let i = frame.lines.length - 1; i >= 0; i--) {
				const line = frame.lines[i];
				if (line.isMacro) continue;
				const pat = line.pat;
				let matches;
				if ((pat.flags & FLAG_MUSTBEDIR) && !isdir) matches = false;
				else if (pat.flags & FLAG_NODIR) matches = matchBasename(path.slice(basenameOffset, path.length - (isdir ? 1 : 0)), pat);
				else matches = matchPathname(path.slice(0, path.length - (isdir ? 1 : 0)), base, base.length, pat);
				if (!matches) continue;
				const todo = line.states.slice();
				while (todo.length) {
					const state = todo.pop();
					if (values.has(state.attr)) continue;
					values.set(state.attr, state.value);
					const macro = macros.get(state.attr);
					if (macro && state.value === true) todo.push(...macro.states);
				}
			}
		}
		return values;
	}

	root.DshNativeGitMatch = {
		wildmatch, WM_PATHNAME, parsePattern, matchBasename, matchPathname, simpleLength,
		excludeList, lastMatching, Excludes, FLAG_NEGATIVE, FLAG_MUSTBEDIR, FLAG_NODIR,
		DT_UNKNOWN, DT_DIR, DT_REG, DT_LNK,
		parseAttrLine, attrFrame, attrsOf, unquoteC, BLANK,
	};
})(globalThis);
