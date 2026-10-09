/*
 * Native read-only Git of deepseek-harness-ipad.
 *
 * Answers the eight git invocations the official dsh-workspace-changes plugin
 * makes (rev-parse, add, write-tree, ls-tree, cat-file, diff-tree, ls-files and
 * check-ignore) without a Linux guest. Behaviour follows git v2.54.0: setup.c
 * discovery, config.c parsing, read-cache.c and dir.c for `add`, cache-tree.c,
 * tree-diff.c and diffcore-rename.c, and the builtins themselves. Anything
 * outside the subset the plugin needs fails closed with exit 128 and
 * `fatal: native git: unsupported: <reason>` instead of guessing.
 *
 * It never writes inside a repository: new objects go only to
 * GIT_OBJECT_DIRECTORY and the only index it writes is GIT_INDEX_FILE, and
 * both must lie outside the work tree and the git directory.
 *
 * Derived from git, Copyright (C) the Git project contributors, licensed under
 * the GNU General Public License version 2.
 */
(function (root) {
	"use strict";

	const { toBytes, fromBytes, bytesOf, stringOf, hexOf, rawOf, Sha1, hashObject, ObjectDb, UnsupportedObjects } = root.DshNativeGitObjects;
	const Match = root.DshNativeGitMatch;
	const Xdiff = root.DshNativeGitXdiff;

	/** A git process exit with its stderr bytes (byte string). */
	class GitExit extends Error {
		constructor(code, stderr) {
			super(`git exit ${code}`);
			this.code = code;
			this.stderr = stderr;
		}
	}

	/** A request outside the supported subset. */
	class Unsupported extends Error {}

	const die = (message) => { throw new GitExit(128, `fatal: ${message}\n`); };
	const unsupported = (reason) => { throw new Unsupported(reason); };

	const S_IFMT = 0o170000, S_IFREG = 0o100000, S_IFDIR = 0o040000, S_IFLNK = 0o120000, S_IFGITLINK = 0o160000;
	const isReg = (mode) => (mode & S_IFMT) === S_IFREG;
	const isDir = (mode) => (mode & S_IFMT) === S_IFDIR;
	const isLnk = (mode) => (mode & S_IFMT) === S_IFLNK;
	const isGitlink = (mode) => (mode & S_IFMT) === S_IFGITLINK;
	const EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
	const OID = /^[0-9a-f]{40}$/;

	const STRERROR = {
		EACCES: "Permission denied",
		ENOENT: "No such file or directory",
		ELOOP: "Too many levels of symbolic links",
		ENOTDIR: "Not a directory",
		EISDIR: "Is a directory",
		EPERM: "Operation not permitted",
		EIO: "Input/output error",
		ENAMETOOLONG: "File name too long",
	};
	const strerror = (error) => STRERROR[error && error.code] ?? (error && error.code ? error.code : String(error && error.message));
	const missing = (error) => error && (error.code === "ENOENT" || error.code === "ENOTDIR");

	/** Lexically normalised absolute host path. */
	function normalize(path) {
		const out = [];
		for (const part of path.split("/")) {
			if (part === "" || part === ".") continue;
			if (part === "..") out.pop();
			else out.push(part);
		}
		return `/${out.join("/")}`;
	}

	/** `path` resolved against the absolute directory `base`. */
	const resolve = (base, path) => normalize(path.startsWith("/") ? path : `${base}/${path}`);

	/** Synchronous host file system access with git's error conventions. */
	class Host {
		constructor(fs) {
			this.fs = fs;
		}

		/** lstat, or null when the path does not exist. */
		lstat(path) {
			try { return this.fs.lstatSync(path); } catch (error) {
				if (missing(error)) return null;
				throw error;
			}
		}

		/** stat following symbolic links, or null when it does not resolve. */
		stat(path) {
			let real;
			try { real = this.fs.realpathSync(path); } catch (error) {
				if (missing(error) || error.code === "ELOOP") return null;
				throw error;
			}
			return this.lstat(real);
		}

		/** realpath, or null when it does not resolve. */
		realpath(path) {
			try { return this.fs.realpathSync(path); } catch (error) {
				if (missing(error) || error.code === "ELOOP") return null;
				throw error;
			}
		}

		read(path) {
			return this.fs.readFileSync(path);
		}

		/** File bytes as a byte string. */
		readBytes(path) {
			return stringOf(this.fs.readFileSync(path));
		}

		readlink(path) {
			return this.fs.readlinkSync(path);
		}

		readdir(path) {
			return this.fs.readdirSync(path);
		}

		/** Whether stat finds a searchable path (access X_OK). */
		executable(path) {
			const st = this.stat(path);
			return st !== null && (st.mode & 0o111) !== 0;
		}
	}

	// --- config (config.c) -------------------------------------------------

	const isConfigSpace = (c) => c === " " || c === "\t" || c === "\n" || c === "\r";
	const isAlnum = (c) => /^[A-Za-z0-9]$/.test(c);
	const isKeyChar = (c) => isAlnum(c) || c === "-";

	/**
	 * Parse one config file the way config.c git_parse_source does.
	 * @param {string} buf - file bytes as a byte string.
	 * @returns {Array<[string, string | null]>} keys with their values, in order.
	 * @throws {Unsupported} on any syntax error.
	 */
	function parseConfig(buf) {
		let pos = 0, eof = false;
		const entries = [];
		const next = () => {
			if (pos >= buf.length) {
				eof = true;
				return "\n";
			}
			let c = buf[pos++];
			if (c === "\r") {
				if (pos < buf.length && buf[pos] === "\n") {
					pos++;
					c = "\n";
				}
			}
			return c;
		};
		const fail = () => unsupported("config syntax");
		const extendedBaseVar = (name, c) => {
			do {
				if (c === "\n") fail();
				c = next();
			} while (isConfigSpace(c));
			if (c !== "\"") fail();
			name += ".";
			for (;;) {
				let d = next();
				if (d === "\n") fail();
				if (d === "\"") break;
				if (d === "\\") {
					d = next();
					if (d === "\n") fail();
				}
				name += d;
			}
			if (next() !== "]") fail();
			return name;
		};
		const baseVar = () => {
			let name = "";
			for (;;) {
				const c = next();
				if (eof) fail();
				if (c === "]") return name;
				if (isConfigSpace(c)) return extendedBaseVar(name, c);
				if (!isKeyChar(c) && c !== ".") fail();
				name += c.toLowerCase();
			}
		};
		const parseValue = () => {
			let quote = false, comment = false, trim = 0, value = "";
			for (;;) {
				let c = next();
				if (c === "\n") {
					if (quote) fail();
					return trim ? value.slice(0, trim) : value;
				}
				if (comment) continue;
				if (isConfigSpace(c) && !quote) {
					if (!trim) trim = value.length;
					if (value.length) value += c;
					continue;
				}
				if (!quote && (c === ";" || c === "#")) {
					comment = true;
					continue;
				}
				if (trim) trim = 0;
				if (c === "\\") {
					c = next();
					if (c === "\n") continue;
					if (c === "t") c = "\t";
					else if (c === "b") c = "\b";
					else if (c === "n") c = "\n";
					else if (c !== "\\" && c !== "\"") fail();
					value += c;
					continue;
				}
				if (c === "\"") {
					quote = !quote;
					continue;
				}
				value += c;
			}
		};
		const BOM = "\xef\xbb\xbf";
		let bom = 0, comment = false, section = null;
		for (;;) {
			const c = next();
			if (bom >= 0 && bom < 3) {
				if (c === BOM[bom]) {
					bom++;
					continue;
				}
				if (bom !== 0) fail();
				bom = -1;
			}
			if (c === "\n") {
				if (eof) return entries;
				comment = false;
				continue;
			}
			if (comment || isConfigSpace(c)) continue;
			if (c === "#" || c === ";") {
				comment = true;
				continue;
			}
			if (c === "[") {
				section = baseVar();
				if (section.length < 1) fail();
				continue;
			}
			if (!/^[A-Za-z]$/.test(c)) fail();
			if (section === null) fail();
			let key = c.toLowerCase(), d;
			for (;;) {
				d = next();
				if (eof || !isKeyChar(d)) break;
				key += d.toLowerCase();
			}
			while (d === " " || d === "\t") d = next();
			let value = null;
			if (d !== "\n") {
				if (d !== "=") fail();
				value = parseValue();
			}
			const nul = value === null ? -1 : value.indexOf("\0");
			entries.push([`${section}.${key}`, nul >= 0 ? value.slice(0, nul) : value]);
		}
	}

	/** strtoimax with base 0 plus git's k/m/g units (parse.c git_parse_signed). */
	function parseConfigInt(value) {
		const m = /^([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)([kKmMgG]?)$/.exec(value);
		if (!m) return null;
		const digits = m[2];
		let n = /^0[xX]/.test(digits) ? parseInt(digits.slice(2), 16) : digits.length > 1 && digits[0] === "0" ? parseInt(digits.slice(1), 8) : parseInt(digits, 10);
		if (m[1] === "-") n = -n;
		const unit = { "": 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3 }[m[3].toLowerCase()];
		n *= unit;
		if (!Number.isSafeInteger(n)) return null;
		return n;
	}

	/** git_parse_maybe_bool: true, false, or null when not a boolean. */
	function parseBool(value) {
		if (value === null) return true;
		if (value === "") return false;
		const lower = value.toLowerCase();
		if (lower === "true" || lower === "yes" || lower === "on") return true;
		if (lower === "false" || lower === "no" || lower === "off") return false;
		const n = parseConfigInt(value);
		return n === null ? null : n !== 0;
	}

	const BUILTIN_DIFF_DRIVERS = new Set(["ada", "bash", "bibtex", "cpp", "csharp", "css", "dts", "elixir", "fortran", "fountain", "golang", "html", "ini", "java", "kotlin", "markdown", "matlab", "objc", "pascal", "perl", "php", "python", "r", "ruby", "rust", "scheme", "tex", "default"]);

	/** The repository config, with every key the subset cannot honour refused. */
	class Config {
		constructor(entries) {
			this.values = new Map();
			for (const [key, value] of entries) {
				const dot = key.indexOf(".");
				const section = key.slice(0, dot);
				if (section === "include" || section === "includeif") unsupported(`config ${key}`);
				this.values.set(key, value);
			}
			for (const [key, value] of this.values) {
				if (key.startsWith("extensions.")) {
					const name = key.slice(11);
					const ok = name === "noop" || name === "preciousobjects" || name === "partialclone" ||
						(name === "objectformat" && value !== null && value.toLowerCase() === "sha1") ||
						(name === "refstorage" && value !== null && value.toLowerCase() === "files");
					if (!ok) unsupported(`config ${key}`);
				}
				if (/^diff\..*\.algorithm$/.test(key)) unsupported(`config ${key}`);
			}
			for (const key of ["core.worktree", "core.excludesfile", "attr.tree", "core.attributesfile"]) {
				if (this.values.has(key)) unsupported(`config ${key}`);
			}
			if (this.bool("core.ignorecase", false)) unsupported("config core.ignorecase=true");
			if (!this.bool("core.symlinks", true)) unsupported("config core.symlinks=false");
			if (this.bool("core.bare", false)) unsupported("config core.bare=true");
			if (this.bool("core.sparsecheckout", false)) unsupported("config core.sparsecheckout=true");
			const version = this.int("core.repositoryformatversion", 0);
			if (version < 0 || version > 1) unsupported(`repository format version ${version}`);
			const autocrlf = this.get("core.autocrlf");
			this.autocrlf = autocrlf !== undefined && autocrlf !== null && autocrlf.toLowerCase() === "input" ? "input" : this.bool("core.autocrlf", false);
			this.filemode = this.bool("core.filemode", true);
			this.precompose = this.bool("core.precomposeunicode", false);
			this.bigFileThreshold = this.int("core.bigfilethreshold", 512 * 1024 * 1024);
			this.renameLimit = this.int("diff.renamelimit", 1000);
			const eol = this.get("core.eol");
			if (eol !== undefined) {
				const lower = eol === null ? null : eol.toLowerCase();
				if (lower !== "lf" && lower !== "crlf" && lower !== "native") unsupported(`config core.eol=${eol}`);
				this.eolCrlf = lower === "crlf";
			} else this.eolCrlf = false;
			if (this.eolCrlf && this.autocrlf === "input") unsupported("config core.eol=crlf with core.autocrlf=input");
			const safecrlf = this.get("core.safecrlf");
			this.safecrlf = safecrlf === undefined || (safecrlf !== null && safecrlf.toLowerCase() === "warn") ? "warn" : this.bool("core.safecrlf", false) ? "die" : "none";
			this.trustctime = this.bool("core.trustctime", true);
			const checkstat = this.get("core.checkstat");
			if (checkstat === undefined || checkstat === "default") this.checkstat = true;
			else if (checkstat === "minimal") this.checkstat = false;
			else unsupported(`config core.checkstat=${checkstat}`);
			for (const key of ["color.advice", "color.ui"]) {
				const value = this.get(key);
				if (value !== undefined && value !== null && value.toLowerCase() === "always") unsupported(`config ${key}=always`);
			}
			this.filterDrivers = new Set();
			for (const key of this.values.keys()) {
				if (key.startsWith("filter.") && key.lastIndexOf(".") > 6) this.filterDrivers.add(key.slice(7, key.lastIndexOf(".")));
			}
		}

		/** advice.c: whether a hint shows, and whether with its "Disable" line. */
		advice(key) {
			const name = `advice.${key.toLowerCase()}`;
			if (!this.values.has(name)) return { show: true, instruction: true };
			return { show: this.bool(name, true), instruction: false };
		}

		/** userdiff.c: the binary setting of a diff driver, -1 meaning auto. */
		diffBinary(name) {
			let exists = BUILTIN_DIFF_DRIVERS.has(name);
			if (!exists) {
				for (const key of this.values.keys()) if (key.startsWith(`diff.${name}.`) && key.lastIndexOf(".") === name.length + 5) exists = true;
			}
			if (!exists) name = "default";
			const key = `diff.${name}.binary`;
			const value = this.get(key);
			if (value === undefined || (value !== null && value.toLowerCase() === "auto")) return -1;
			return this.bool(key, false) ? 1 : 0;
		}


		get(key) {
			return this.values.get(key);
		}

		bool(key, fallback) {
			if (!this.values.has(key)) return fallback;
			const parsed = parseBool(this.values.get(key));
			if (parsed === null) unsupported(`config ${key} is not a boolean`);
			return parsed;
		}

		int(key, fallback) {
			if (!this.values.has(key)) return fallback;
			const value = this.values.get(key);
			const parsed = value === null ? null : parseConfigInt(value);
			if (parsed === null) unsupported(`config ${key} is not a number`);
			return parsed;
		}

		/** Whether any submodule settings are present. */
		hasSubmoduleConfig() {
			for (const key of this.values.keys()) if (key.startsWith("submodule.") || key === "diff.ignoresubmodules") return true;
			return false;
		}
	}

	// --- index (read-cache.c) ----------------------------------------------

	const be32 = (b, i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
	const be16 = (b, i) => (b[i] << 8) | b[i + 1];
	const KNOWN_EXTENSIONS = new Set(["TREE", "REUC", "UNTR", "FSMN", "EOIE", "IEOT"]);

	/** Byte order of index entries: name bytes, then stage. */
	const compareEntries = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.stage - b.stage);

	/**
	 * Parse an index file.
	 * @param {Uint8Array} data - file bytes.
	 * @param {(message: string) => void} warn - stderr sink.
	 * @returns {{name: string, mode: number, oid: string, stage: number, stat: Uint8Array}[]}
	 */
	function parseIndex(data, warn) {
		const corrupt = (message) => {
			throw new GitExit(128, `error: ${message}\nfatal: index file corrupt\n`);
		};
		if (data.length < 12 + 20) die("index file smaller than expected");
		if (stringOf(data, 0, 4) !== "DIRC") corrupt(`bad signature 0x${be32(data, 0).toString(16).padStart(8, "0")}`);
		const version = be32(data, 4);
		if (version < 2 || version > 4) corrupt(`bad index version ${version}`);
		const trailer = data.subarray(data.length - 20);
		if (trailer.some((b) => b !== 0)) {
			const sha = new Sha1();
			sha.update(data.subarray(0, data.length - 20));
			const digest = sha.digest();
			if (digest.some((b, i) => b !== trailer[i])) corrupt("bad index file sha1 signature");
		}
		const count = be32(data, 8);
		const entries = [];
		let at = 12, previous = "";
		for (let n = 0; n < count; n++) {
			if (at + 62 > data.length - 20) corrupt("index entry out of range");
			const stat = data.slice(at, at + 40);
			const mode = be32(data, at + 24);
			const oid = hexOf(data, at + 40, at + 60);
			const flags = be16(data, at + 60);
			let nameAt = at + 62;
			if (flags & 0x8000) unsupported("index entry with assume-unchanged");
			if (flags & 0x4000) {
				if (version < 3) corrupt("extended flags in a version 2 index");
				const extended = be16(data, at + 62);
				if (extended & 0x4000) unsupported("index entry with skip-worktree");
				if (extended & 0x2000) unsupported("index entry with intent-to-add");
				if (extended & ~0x6000) die(`unknown index entry format 0x${(((flags << 16) | extended) >>> 0).toString(16).padStart(8, "0")}`);
				nameAt += 2;
			}
			let name;
			if (version === 4) {
				let c = data[nameAt++], strip = c & 127;
				while (c & 128) {
					c = data[nameAt++];
					strip = ((strip + 1) << 7) + (c & 127);
				}
				if (strip > previous.length) corrupt("malformed name field in the index");
				const end = data.indexOf(0, nameAt);
				if (end < 0 || end >= data.length - 20) corrupt("malformed name field in the index");
				name = previous.slice(0, previous.length - strip) + stringOf(data, nameAt, end);
				at = end + 1;
			} else {
				const end = data.indexOf(0, nameAt);
				if (end < 0 || end >= data.length - 20) corrupt("malformed name field in the index");
				name = stringOf(data, nameAt, end);
				at = (nameAt - at + name.length + 8 & ~7) + at;
			}
			if ((mode & S_IFMT) === S_IFDIR) unsupported("sparse index");
			const entry = { name, mode, oid, stage: (flags >> 12) & 3, stat };
			if (entries.length && compareEntries(entries[entries.length - 1], entry) >= 0) unsupported("index entries out of order");
			entries.push(entry);
			previous = name;
		}
		while (at + 8 <= data.length - 20) {
			const signature = stringOf(data, at, at + 4);
			const size = be32(data, at + 4);
			if (signature === "link" || signature === "sdir") unsupported(`index extension ${signature}`);
			if (!KNOWN_EXTENSIONS.has(signature)) {
				if (!(signature.charCodeAt(0) >= 0x41 && signature.charCodeAt(0) <= 0x5a)) {
					throw new GitExit(128, `error: index uses ${signature} extension, which we do not understand\nfatal: index file corrupt\n`);
				}
				warn(`ignoring ${signature} extension\n`);
			}
			at += 8 + size;
		}
		return entries;
	}

	/** Seconds and nanoseconds of an lstat time, preferring the nanosecond field. */
	function timeOf(st, which) {
		const ns = st[`${which}Ns`];
		if (ns !== undefined) {
			const big = BigInt(ns);
			return [Number(big / 1000000000n), Number(big % 1000000000n)];
		}
		const ms = Number(st[`${which}Ms`] ?? 0);
		return [Math.floor(ms / 1000), Math.floor((ms % 1000) * 1e6)];
	}

	/** Raw 40-byte stat data of a new entry, from lstat. */
	function statBytes(st) {
		const out = new Uint8Array(40);
		const view = new DataView(out.buffer);
		const [cs, cn] = timeOf(st, "ctime"), [ms, mn] = timeOf(st, "mtime");
		view.setUint32(0, cs >>> 0);
		view.setUint32(4, cn >>> 0);
		view.setUint32(8, ms >>> 0);
		view.setUint32(12, mn >>> 0);
		view.setUint32(16, Number(st.dev ?? 0) >>> 0);
		view.setUint32(20, Number(st.ino ?? 0) >>> 0);
		view.setUint32(24, Number(st.mode ?? 0) >>> 0);
		view.setUint32(28, Number(st.uid ?? 0) >>> 0);
		view.setUint32(32, Number(st.gid ?? 0) >>> 0);
		view.setUint32(36, Number(st.size ?? 0) >>> 0);
		return out;
	}

	/** Serialise entries as a version 2 index without extensions. */
	function serializeIndex(entries) {
		const parts = [];
		let length = 12;
		for (const entry of entries) {
			const size = (62 + entry.name.length + 8) & ~7;
			const buf = new Uint8Array(size);
			buf.set(entry.stat.subarray(0, 40));
			const view = new DataView(buf.buffer);
			view.setUint32(24, entry.mode);
			buf.set(rawOf(entry.oid), 40);
			view.setUint16(60, (entry.stage << 12) | Math.min(entry.name.length, 0xfff));
			buf.set(bytesOf(entry.name), 62);
			parts.push(buf);
			length += size;
		}
		const out = new Uint8Array(length + 20);
		out.set(bytesOf("DIRC"));
		const view = new DataView(out.buffer);
		view.setUint32(4, 2);
		view.setUint32(8, entries.length);
		let at = 12;
		for (const part of parts) {
			out.set(part, at);
			at += part.length;
		}
		const sha = new Sha1();
		sha.update(out.subarray(0, length));
		out.set(sha.digest(), length);
		return out;
	}

	/**
	 * Position of a name among sorted entries (read-cache.c index_name_stage_pos):
	 * the index of the stage-0 entry when present, else -(insert position)-1.
	 */
	function indexPos(entries, name, stage = 0) {
		let lo = 0, hi = entries.length;
		while (lo < hi) {
			const mid = (lo + hi) >> 1;
			const e = entries[mid];
			const cmp = e.name < name ? -1 : e.name > name ? 1 : e.stage - stage;
			if (cmp === 0) return mid;
			if (cmp < 0) lo = mid + 1;
			else hi = mid;
		}
		return -lo - 1;
	}

	// --- discovery (setup.c, path.c) ---------------------------------------

	/** path.c relative_path for '/'-separated paths. */
	function relativePath(input, prefix) {
		if (!input.length) return "./";
		if (!prefix.length) return input;
		if (input.startsWith("/") !== prefix.startsWith("/")) return input;
		const sep = (s, k) => s[k] === "/";
		let i = 0, j = 0, inOff = 0, prefixOff = 0;
		while (i < prefix.length && j < input.length && prefix[i] === input[j]) {
			if (sep(prefix, i)) {
				while (sep(prefix, i)) i++;
				while (sep(input, j)) j++;
				prefixOff = i;
				inOff = j;
			} else {
				i++;
				j++;
			}
		}
		if (i >= prefix.length && prefixOff < prefix.length) {
			if (j >= input.length) inOff = input.length;
			else if (sep(input, j)) {
				while (sep(input, j)) j++;
				inOff = j;
			} else i = prefixOff;
		} else if (j >= input.length && inOff < input.length) {
			if (sep(prefix, i)) {
				while (sep(prefix, i)) i++;
				inOff = input.length;
			}
		}
		const rest = input.slice(inOff);
		if (i >= prefix.length) return rest.length ? rest : "./";
		let out = "";
		while (i < prefix.length) {
			if (sep(prefix, i)) {
				out += "../";
				while (sep(prefix, i)) i++;
				continue;
			}
			i++;
		}
		if (!sep(prefix, prefix.length - 1)) out += "../";
		return out + rest;
	}

	const GITFILE = { OK: 0, MISSING: 1, STAT_FAILED: 2, NOT_A_FILE: 3, IS_A_DIR: 4, TOO_LARGE: 5, OPEN_FAILED: 6, READ_FAILED: 7, INVALID_FORMAT: 8, NO_PATH: 9, NOT_A_REPO: 10 };

	/** stat() for discovery: the result, or a GITFILE error code. */
	function statFollow(host, path) {
		let real;
		try { real = host.fs.realpathSync(path); } catch (error) {
			return missing(error) ? GITFILE.MISSING : GITFILE.STAT_FAILED;
		}
		try { return host.fs.lstatSync(real); } catch (error) {
			return missing(error) ? GITFILE.MISSING : GITFILE.STAT_FAILED;
		}
	}

	/** A host path from repository bytes, refusing names that are not UTF-8. */
	function hostPath(bytes) {
		try { return fromBytes(bytes); } catch { return unsupported("path that is not UTF-8"); }
	}

	/** setup.c get_common_dir_noenv. */
	function commonDirOf(host, gitdir) {
		const file = `${gitdir}/commondir`;
		const st = statFollow(host, file);
		if (typeof st === "number") return { dir: gitdir, linked: false };
		let data;
		try { data = host.readBytes(file); } catch (error) {
			die(`failed to read ${toBytes(file)}: ${strerror(error)}`);
		}
		if (!data.length) die(`failed to read ${toBytes(file)}`);
		data = data.replace(/[\r\n]+$/, "");
		const nul = data.indexOf("\0");
		if (nul >= 0) data = data.slice(0, nul);
		const target = hostPath(data);
		const joined = target.startsWith("/") ? target : `${gitdir}/${target}`;
		const real = host.realpath(joined);
		if (real === null) die(`Invalid path '${toBytes(joined)}': No such file or directory`);
		return { dir: real, linked: true };
	}

	/** setup.c validate_headref. */
	function validHead(host, path) {
		const st = host.lstat(path);
		if (!st) return false;
		if (isLnk(st.mode)) {
			try { return host.readlink(path).startsWith("refs/"); } catch { return false; }
		}
		let text;
		try { text = stringOf(host.read(path).subarray(0, 255)); } catch { return false; }
		const nul = text.indexOf("\0");
		if (nul >= 0) text = text.slice(0, nul);
		if (text.startsWith("ref:")) {
			let k = 4;
			while (k < text.length && isConfigSpace(text[k])) k++;
			if (text.startsWith("refs/", k)) return true;
		}
		return /^[0-9a-fA-F]{40}/.test(text);
	}

	/** setup.c is_git_directory. */
	function isGitDirectory(host, suspect, env) {
		if (!validHead(host, `${suspect.replace(/\/$/, "")}/HEAD`)) return false;
		const common = commonDirOf(host, suspect).dir;
		const objects = env.GIT_OBJECT_DIRECTORY ?? `${common}/objects`;
		if (!host.executable(objects)) return false;
		return host.executable(`${common}/refs`);
	}

	/** setup.c read_gitfile_gently: {code, path}. */
	function readGitfile(host, path, env) {
		const st = statFollow(host, path);
		if (typeof st === "number") return { code: st };
		if (isDir(st.mode)) return { code: GITFILE.IS_A_DIR };
		if (!isReg(st.mode)) return { code: GITFILE.NOT_A_FILE };
		if (st.size > 1 << 20) return { code: GITFILE.TOO_LARGE };
		let buf;
		try { buf = host.readBytes(path); } catch { return { code: GITFILE.OPEN_FAILED }; }
		if (buf.length !== st.size) return { code: GITFILE.READ_FAILED };
		if (!buf.startsWith("gitdir: ")) return { code: GITFILE.INVALID_FORMAT };
		let len = buf.length;
		while (buf[len - 1] === "\n" || buf[len - 1] === "\r") len--;
		if (len < 9) return { code: GITFILE.NO_PATH };
		let target = buf.slice(8, len);
		const nul = target.indexOf("\0");
		if (nul >= 0) target = target.slice(0, nul);
		let dir = hostPath(target);
		if (!dir.startsWith("/")) dir = `${path.slice(0, path.lastIndexOf("/") + 1)}${dir}`;
		if (!isGitDirectory(host, dir, env)) return { code: GITFILE.NOT_A_REPO, dir };
		const real = host.realpath(dir);
		if (real === null) die(`Invalid path '${toBytes(dir)}': No such file or directory`);
		return { code: GITFILE.OK, path: real };
	}

	/** setup.c read_gitfile_error_die for the fatal codes. */
	function gitfileDie(code, path, dir) {
		const p = toBytes(path);
		switch (code) {
		case GITFILE.OPEN_FAILED: return die(`error opening '${p}'`);
		case GITFILE.TOO_LARGE: return die(`too large to be a .git file: '${p}'`);
		case GITFILE.READ_FAILED: return die(`error reading ${p}`);
		case GITFILE.INVALID_FORMAT: return die(`invalid gitfile format: ${p}`);
		case GITFILE.NO_PATH: return die(`no path in gitfile: ${p}`);
		case GITFILE.NOT_A_REPO: return die(`not a git repository: ${dir === null ? "(null)" : toBytes(dir)}`);
		default: throw new Error(`gitfile code ${code}`);
		}
	}

	/** Ceiling offset (path.c longest_ancestor_length over canonical GIT_CEILING_DIRECTORIES). */
	function ceilingOffset(host, dir, env) {
		const value = env.GIT_CEILING_DIRECTORIES;
		if (value === undefined || dir === "/") return -1;
		let emptySeen = false, best = -1;
		for (let ceil of value.split(":")) {
			if (ceil === "") {
				emptySeen = true;
				continue;
			}
			if (!ceil.startsWith("/")) continue;
			if (!emptySeen) {
				const real = host.realpath(ceil);
				if (real === null) continue;
				ceil = real;
			}
			let len = ceil.length;
			if (len > 0 && ceil[len - 1] === "/") len--;
			if (dir.slice(0, len) !== ceil.slice(0, len) || dir[len] !== "/" || dir.length === len + 1) continue;
			if (len > best) best = len;
		}
		return best;
	}

	/**
	 * setup.c setup_git_directory_gently_1 from `cwd`.
	 * @returns {{worktree: string | null, gitdir: string, dotGit: boolean, prefix: string}}
	 */
	function discover(host, cwd, env) {
		let dir = host.realpath(cwd);
		if (dir === null) die("Unable to read current working directory: No such file or directory");
		const start = dir;
		const ceil = ceilingOffset(host, dir, env);
		const deviceOf = (path) => {
			const st = host.stat(path);
			if (!st) die(`failed to stat '${toBytes(path)}'`);
			return st.dev;
		};
		const device = deviceOf(dir);
		for (;;) {
			const dotGit = dir === "/" ? "/.git" : `${dir}/.git`;
			const found = readGitfile(host, dotGit, env);
			let gitdir = null, isDotGit = false;
			switch (found.code) {
			case GITFILE.OK: gitdir = found.path; break;
			case GITFILE.MISSING: break;
			case GITFILE.IS_A_DIR:
				if (isGitDirectory(host, dotGit, env)) {
					gitdir = dotGit;
					isDotGit = true;
				}
				break;
			case GITFILE.STAT_FAILED: return die(`error reading '${toBytes(dotGit)}'`);
			case GITFILE.NOT_A_FILE: return die(`not a regular file: '${toBytes(dotGit)}'`);
			default: return gitfileDie(found.code, dotGit, null);
			}
			if (gitdir !== null) {
				const prefix = start === dir ? "" : `${start.slice(dir === "/" ? 1 : dir.length + 1)}/`;
				return { worktree: dir, gitdir, dotGit: isDotGit, prefix };
			}
			if (isGitDirectory(host, dir, env)) return { worktree: null, gitdir: dir, dotGit: false, prefix: "" };
			if (dir === "/") die("not a git repository (or any of the parent directories): .git");
			const slash = dir.lastIndexOf("/");
			if (slash <= ceil) die("not a git repository (or any of the parent directories): .git");
			dir = slash > 0 ? dir.slice(0, slash) : "/";
			if (deviceOf(dir) !== device) {
				die(`not a git repository (or any parent up to mount point ${toBytes(dir)})\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).`);
			}
		}
	}

	// --- invocation (git.c, environment.c) --------------------------------

	const PASSIVE_ENV = new Set(["GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_CONFIG_NOSYSTEM", "GIT_ATTR_NOSYSTEM", "GIT_PAGER", "GIT_EDITOR", "GIT_ASKPASS"]);

	/**
	 * The GIT_* environment the subset honours; anything else is refused.
	 * @returns {{GIT_OBJECT_DIRECTORY?: string, GIT_ALTERNATE_OBJECT_DIRECTORIES?: string[], GIT_INDEX_FILE?: string, GIT_CEILING_DIRECTORIES?: string, literal: boolean}}
	 */
	function gitEnv(env, cwd, command) {
		const out = { literal: false };
		for (const [key, value] of Object.entries(env ?? {})) {
			if (!key.startsWith("GIT_") || value === undefined) continue;
			if (PASSIVE_ENV.has(key)) continue;
			if (key === "GIT_CONFIG_COUNT") {
				if (value !== "0") unsupported(`environment ${key}=${value}`);
			} else if (key === "GIT_CONFIG_GLOBAL") {
				if (value !== "/dev/null") unsupported(`environment ${key}`);
			} else if (key === "GIT_CEILING_DIRECTORIES") {
				out[key] = value;
			} else if (key === "GIT_LITERAL_PATHSPECS") {
				if (command !== "ls-tree") unsupported(`environment ${key} for ${command}`);
				out.literal = parseBool(value) === true;
			} else if (key === "GIT_OBJECT_DIRECTORY" || key === "GIT_INDEX_FILE") {
				if (command === "rev-parse" || value === "") unsupported(`environment ${key} for ${command}`);
				out[key] = resolve(cwd, value);
			} else if (key === "GIT_ALTERNATE_OBJECT_DIRECTORIES") {
				if (command === "rev-parse" || value.startsWith("\"")) unsupported(`environment ${key} for ${command}`);
				out[key] = value.split(":").filter((dir) => dir !== "").map((dir) => resolve(cwd, dir));
			} else unsupported(`environment ${key}`);
		}
		return out;
	}

	const isNormalPath = (path) => path !== "" && path.split("/").every((part) => part !== "" && part !== "." && part !== "..");
	const hasGlob = (path) => /[*?[\\]/.test(path);

	/** realpath of the deepest existing ancestor, with the rest appended. */
	function realish(host, path) {
		let head = normalize(path), tail = "";
		for (;;) {
			const real = host.realpath(head);
			if (real !== null) return tail ? `${real === "/" ? "" : real}/${tail}` : real;
			if (head === "/") return normalize(path);
			const slash = head.lastIndexOf("/");
			const part = head.slice(slash + 1);
			tail = tail ? `${part}/${tail}` : part;
			head = slash > 0 ? head.slice(0, slash) : "/";
		}
	}

	const within = (path, dir) => path === dir || path.startsWith(dir === "/" ? "/" : `${dir}/`);

	// --- repository --------------------------------------------------------

	/** Discovery plus the shared config. */
	function openRepo(host, cwd, env) {
		const found = discover(host, cwd, env);
		const common = commonDirOf(host, found.gitdir);
		let buf = "";
		try { buf = host.readBytes(`${common.dir}/config`); } catch (error) {
			if (!missing(error)) throw error;
		}
		const config = new Config(parseConfig(buf));
		return { host, ...found, common: common.dir, linked: common.linked, config };
	}

	/** The object databases, refusing replace refs. */
	function openObjects(ctx) {
		const { host, repo, env } = ctx;
		if (host.lstat(`${repo.common}/refs/replace`)) unsupported("replace refs");
		let packed = "";
		try { packed = host.readBytes(`${repo.common}/packed-refs`); } catch (error) {
			if (!missing(error)) throw error;
		}
		if (/ refs\/replace\//.test(packed)) unsupported("replace refs");
		ctx.db = new ObjectDb(host.fs, env.GIT_OBJECT_DIRECTORY ?? `${repo.common}/objects`, env.GIT_ALTERNATE_OBJECT_DIRECTORIES ?? []);
		return ctx.db;
	}

	/** Refuse write targets inside the git directory, or inside the work tree unless a pathspec exclude covers them. */
	function checkWriteTargets(ctx, excludes) {
		const { host, repo, env } = ctx;
		const dirs = [repo.gitdir, repo.common].map((dir) => host.realpath(dir) ?? dir);
		for (const key of ["GIT_OBJECT_DIRECTORY", "GIT_INDEX_FILE"]) {
			if (env[key] === undefined) unsupported(`writing without ${key}`);
			const targets = key === "GIT_INDEX_FILE" ? [env[key], `${env[key]}.lock`] : [env[key]];
			for (const target of targets) {
				const real = realish(host, target);
				if (dirs.some((dir) => within(real, dir))) unsupported(`${key} inside the git directory`);
				if (excludes !== null && within(real, repo.worktree)) {
					const rel = toBytes(real.slice(repo.worktree.length + 1));
					if (!excludes.some((m) => rel === m || rel.startsWith(`${m}/`))) unsupported(`${key} inside the work tree`);
				}
			}
		}
	}

	/** lockfile.c hold_lock_file_for_update with LOCK_DIE_ON_ERROR. */
	function takeLock(ctx, file) {
		const path = `${file}.lock`;
		try { ctx.host.fs.writeFileSync(path, "", { flag: "wx" }); } catch (error) {
			if (error && error.code === "EEXIST") die(`Unable to create '${toBytes(path)}': File exists.\n\nAnother git process seems to be running in this repository, or the lock file may be stale`);
			die(`Unable to create '${toBytes(path)}': ${strerror(error)}`);
		}
		ctx.locks.push(path);
		return path;
	}

	/** The index of a repository: GIT_INDEX_FILE or the git directory's own. */
	const indexFileOf = (ctx) => ctx.env.GIT_INDEX_FILE ?? `${ctx.repo.gitdir}/index`;

	/** read-cache.c do_read_index: entries plus the file's mtime seconds. */
	function readIndexFile(ctx, file) {
		let data;
		try { data = ctx.host.read(file); } catch (error) {
			if (error && error.code === "ENOENT") return { entries: [], timestamp: 0, changed: false };
			die(`${toBytes(file)}: index file open failed: ${strerror(error)}`);
		}
		if (data.length < 32) die(`${toBytes(file)}: index file smaller than expected`);
		const st = ctx.host.stat(file);
		return { entries: parseIndex(data, ctx.err), timestamp: st ? timeOf(st, "mtime")[0] : 0, changed: false };
	}

	/** Commit the locked index: write it under the lock name, then rename. */
	function commitIndex(ctx, file, lock, entries) {
		ctx.host.fs.writeFileSync(lock, serializeIndex(entries));
		ctx.host.fs.renameSync(lock, file);
		ctx.locks.splice(ctx.locks.indexOf(lock), 1);
	}

	// --- objects -----------------------------------------------------------

	/** tree-walk.c canon_mode. */
	function canonMode(mode) {
		if (isReg(mode)) return S_IFREG | (mode & 0o100 ? 0o755 : 0o644);
		if (isDir(mode)) return S_IFDIR;
		if (isLnk(mode)) return S_IFLNK;
		return S_IFGITLINK;
	}

	/** Entries of a tree object. */
	function parseTree(data) {
		const out = [];
		let at = 0;
		while (at < data.length) {
			const space = data.indexOf(0x20, at);
			const nul = space < 0 ? -1 : data.indexOf(0, space);
			if (nul < 0 || nul + 21 > data.length) unsupported("corrupt tree object");
			const mode = parseInt(stringOf(data, at, space), 8);
			out.push({ name: stringOf(data, space + 1, nul), mode: canonMode(mode), oid: hexOf(data, nul + 1, nul + 21) });
			at = nul + 21;
		}
		return out;
	}

	/** The object id a tag or commit points at, by its header line. */
	function headerOid(data, field) {
		const text = stringOf(data, 0, Math.min(data.length, 200));
		const m = new RegExp(`^${field} ([0-9a-f]{40})\\n`).exec(text);
		return m ? m[1] : null;
	}

	/** Peel tags (and commits, to their tree) until `want`; null when it cannot. */
	function peel(db, oid, want) {
		for (let depth = 0; depth < 64; depth++) {
			const obj = db.read(oid);
			if (!obj) return null;
			if (obj.type === want) return { oid, data: obj.data };
			if (obj.type === "tag") oid = headerOid(obj.data, "object");
			else if (obj.type === "commit" && want === "tree") oid = headerOid(obj.data, "tree");
			else return null;
			if (oid === null) unsupported("corrupt tag or commit");
		}
		return null;
	}

	// --- stat and the work tree (read-cache.c, entry.c) ---------------------

	const EMPTY_BLOB = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
	const u32 = (bytes, at) => new DataView(bytes.buffer, bytes.byteOffset, 40).getUint32(at);

	/** read-cache.c ce_mode_from_stat. */
	function modeFromStat(config, entry, st) {
		if (isReg(st.mode) && !config.filemode && entry && isReg(entry.mode)) return entry.mode;
		if (isLnk(st.mode)) return S_IFLNK;
		if (isDir(st.mode)) return S_IFGITLINK;
		return S_IFREG | (st.mode & 0o100 ? 0o755 : 0o644);
	}

	/** The work tree path of a repository name. */
	const workPath = (ctx, name) => `${ctx.repo.worktree}/${hostPath(name)}`;

	/**
	 * read-cache.c ie_match_stat with CE_MATCH_RACY_IS_DIRTY: true when the entry may differ.
	 * @param {object} index - {entries, timestamp}.
	 */
	function entryChanged(ctx, index, entry, st) {
		const { config } = ctx;
		if (isReg(entry.mode)) {
			if (!isReg(st.mode)) return true;
			if (config.filemode && ((entry.mode ^ st.mode) & 0o100)) return true;
		} else if (isLnk(entry.mode)) {
			if (!isLnk(st.mode)) return true;
		} else if (isGitlink(entry.mode)) {
			if (!isDir(st.mode)) return true;
			const head = nestedHead(ctx, workPath(ctx, entry.name));
			return head !== null && head !== entry.oid;
		} else return true;
		const s = entry.stat;
		const [cs] = timeOf(st, "ctime"), [ms] = timeOf(st, "mtime");
		let changed = u32(s, 8) !== (ms >>> 0);
		if (config.trustctime && config.checkstat && u32(s, 0) !== (cs >>> 0)) changed = true;
		if (config.checkstat) {
			if (u32(s, 28) !== (Number(st.uid) >>> 0) || u32(s, 32) !== (Number(st.gid) >>> 0)) changed = true;
			if (u32(s, 20) !== (Number(st.ino) >>> 0)) changed = true;
		}
		if (u32(s, 36) !== (Number(st.size) >>> 0)) changed = true;
		if (!changed && u32(s, 36) === 0 && entry.oid !== EMPTY_BLOB) changed = true;
		if (changed) return true;
		// CE_MATCH_RACY_IS_DIRTY: add treats a racily clean entry as modified.
		return index.timestamp !== 0 && index.timestamp <= u32(s, 8);
	}

	// --- submodules (refs/files-backend.c, refs.c) -------------------------

	/**
	 * HEAD of a nested repository at `dir` (resolve_gitlink_ref), or null.
	 * @param {string} dir - host path of the directory.
	 */
	function nestedHead(ctx, dir) {
		const { host } = ctx;
		let gitdir = `${dir}/.git`;
		const found = readGitfile(host, gitdir, ctx.env);
		if (found.code === GITFILE.OK) gitdir = found.path;
		else if (found.code !== GITFILE.IS_A_DIR || !isGitDirectory(host, gitdir, ctx.env)) return null;
		const common = commonDirOf(host, gitdir).dir;
		let buf = "";
		try { buf = host.readBytes(`${common}/config`); } catch (error) {
			if (!missing(error)) throw error;
		}
		for (const [key, value] of parseConfig(buf)) {
			if (key.startsWith("extensions.")) {
				const name = key.slice(11);
				if (name === "objectformat" || name === "refstorage") {
					if (value === null || value.toLowerCase() !== (name === "refstorage" ? "files" : "sha1")) unsupported(`nested repository ${key}`);
				} else if (name !== "noop" && name !== "preciousobjects" && name !== "partialclone" && name !== "worktreeconfig") unsupported(`nested repository ${key}`);
			}
		}
		let ref = "HEAD";
		for (let depth = 0; depth <= 5; depth++) {
			const perWorktree = ref === "HEAD" || !ref.startsWith("refs/") || /^refs\/(bisect|worktree|rewritten)\//.test(ref);
			const file = `${perWorktree ? gitdir : common}/${hostPath(ref)}`;
			const st = host.lstat(file);
			let text = null;
			if (st && isLnk(st.mode)) unsupported("symbolic link ref");
			if (st && isReg(st.mode)) text = host.readBytes(file);
			else if (st && isDir(st.mode)) return null;
			if (text === null) {
				if (perWorktree && ref === "HEAD") return null;
				let packed = "";
				try { packed = host.readBytes(`${common}/packed-refs`); } catch (error) {
					if (!missing(error)) throw error;
				}
				for (const line of packed.split("\n")) {
					if (line.startsWith("#") || line.startsWith("^")) continue;
					if (line.slice(41) === ref && OID.test(line.slice(0, 40))) return line.slice(0, 40);
				}
				return null;
			}
			const m = /^ref:[ \t\n\r]*(\S+)/.exec(text);
			if (m) {
				ref = m[1];
				continue;
			}
			const hex = /^([0-9a-f]{40})(\s|$)/.exec(text);
			return hex ? hex[1] : null;
		}
		return null;
	}

	// --- ignores and attributes (dir.c, attr.c) ----------------------------

	/** dir.c add_patterns: the .gitignore of a directory, or null. */
	function loadIgnore(ctx, dir) {
		const rel = dir === "" ? ".gitignore" : `${dir}/.gitignore`;
		const path = workPath(ctx, rel);
		const st = ctx.host.lstat(path);
		if (!st || isDir(st.mode)) return null;
		if (isLnk(st.mode)) {
			ctx.err(`warning: unable to access '${rel}': Too many levels of symbolic links\n`);
			return null;
		}
		let buf;
		try { buf = ctx.host.readBytes(path); } catch (error) {
			if (missing(error)) return null;
			ctx.err(`warning: unable to access '${rel}': ${strerror(error)}\n`);
			return null;
		}
		if (!buf.length) return null;
		return `${buf}\n`;
	}

	/** The exclude engine with info/exclude. */
	function excludesOf(ctx) {
		if (ctx.excludes) return ctx.excludes;
		let info = null;
		try {
			const buf = ctx.host.readBytes(`${ctx.repo.common}/info/exclude`);
			if (buf.length) info = Match.excludeList(`${buf}\n`, "");
		} catch (error) {
			if (!missing(error) && error.code !== "EISDIR") throw error;
		}
		ctx.excludes = new Match.Excludes((dir) => loadIgnore(ctx, dir), info);
		return ctx.excludes;
	}

	const ATTR_MAX = 100 * 1024 * 1024;

	/** Lines of a .gitattributes buffer (attr.c read_attr_from_buf). */
	function attrLines(buf) {
		const lines = buf.split("\n");
		if (lines[lines.length - 1] === "") lines.pop();
		if (lines.length && lines[0].startsWith("\xef\xbb\xbf")) lines[0] = lines[0].slice(3);
		return lines.map((line) => (line.endsWith("\r") ? line.slice(0, -1) : line));
	}

	/** attr.c read_attr: a directory's .gitattributes from the work tree, else the index. */
	function loadAttrs(ctx, index, dir) {
		const rel = dir === "" ? ".gitattributes" : `${dir}/.gitattributes`;
		const path = workPath(ctx, rel);
		const st = ctx.host.lstat(path);
		let buf = null;
		if (st && isLnk(st.mode)) ctx.err(`warning: unable to access '${rel}': Too many levels of symbolic links\n`);
		else if (st && isDir(st.mode)) unsupported(".gitattributes that is a directory");
		else if (st && st.size >= ATTR_MAX) ctx.err(`warning: ignoring overly large gitattributes file '${rel}'\n`);
		else if (st) {
			try { buf = ctx.host.readBytes(path); } catch (error) {
				if (!missing(error)) ctx.err(`warning: unable to access '${rel}': ${strerror(error)}\n`);
			}
		}
		if (buf === null && index) {
			let pos = indexPos(index.entries, rel, 0);
			if (pos < 0) pos = indexPos(index.entries, rel, 2);
			if (pos >= 0) {
				const entry = index.entries[pos];
				const obj = isReg(entry.mode) || isLnk(entry.mode) ? ctx.db.read(entry.oid) : null;
				if (obj && obj.type === "blob") {
					if (obj.data.length >= ATTR_MAX) ctx.err(`warning: ignoring overly large gitattributes blob '${rel}'\n`);
					else buf = stringOf(obj.data);
				}
			}
		}
		return buf === null ? [] : attrLines(buf);
	}

	/** Attribute values of a path (attr.c git_check_attr), with frames cached per directory. */
	function attrsFor(ctx, index, name) {
		if (!ctx.attrFrames) {
			ctx.attrFrames = new Map();
			let info = [];
			try { info = attrLines(ctx.host.readBytes(`${ctx.repo.common}/info/attributes`)); } catch (error) {
				if (!missing(error) && error.code !== "EISDIR") throw error;
			}
			ctx.attrInfo = { origin: null, lines: Match.attrFrame(info, true, ctx.err, "info/attributes") };
			ctx.attrBuiltin = { origin: null, lines: Match.attrFrame(["[attr]binary -diff -merge -text"], true, ctx.err, "[builtin]") };
		}
		const frameOf = (dir) => {
			let frame = ctx.attrFrames.get(dir);
			if (!frame) {
				const src = dir === "" ? ".gitattributes" : `${dir}/.gitattributes`;
				frame = { origin: dir, lines: Match.attrFrame(loadAttrs(ctx, index, dir), dir === "", ctx.err, src) };
				ctx.attrFrames.set(dir, frame);
			}
			return frame;
		};
		const stack = [ctx.attrInfo];
		let dir = name;
		for (;;) {
			const slash = dir.lastIndexOf("/");
			dir = slash < 0 ? "" : dir.slice(0, slash);
			stack.push(frameOf(dir));
			if (dir === "") break;
		}
		stack.push(ctx.attrBuiltin);
		return Match.attrsOf(name, stack);
	}

	// --- content conversion (convert.c) -------------------------------------

	const CRLF = { UNDEFINED: 0, BINARY: 1, TEXT: 2, TEXT_INPUT: 3, TEXT_CRLF: 4, AUTO: 5, AUTO_INPUT: 6, AUTO_CRLF: 7 };

	/** convert.c text_eol_is_crlf. */
	const eolIsCrlf = (config) => config.autocrlf === true || (config.autocrlf !== "input" && config.eolCrlf);

	/** convert.c convert_attrs: the crlf action of a path. */
	function crlfAction(ctx, attrs) {
		const { config } = ctx;
		const check = (value) => {
			if (value === true) return CRLF.TEXT;
			if (value === false) return CRLF.BINARY;
			if (value === "input") return CRLF.TEXT_INPUT;
			if (value === "auto") return CRLF.AUTO;
			return CRLF.UNDEFINED;
		};
		let action = check(attrs.get("text"));
		if (action === CRLF.UNDEFINED) action = check(attrs.get("crlf"));
		if (action !== CRLF.BINARY) {
			const eol = attrs.get("eol");
			if (action === CRLF.AUTO && eol === "lf") action = CRLF.AUTO_INPUT;
			else if (action === CRLF.AUTO && eol === "crlf") action = CRLF.AUTO_CRLF;
			else if (eol === "lf") action = CRLF.TEXT_INPUT;
			else if (eol === "crlf") action = CRLF.TEXT_CRLF;
		}
		if (action === CRLF.TEXT) action = eolIsCrlf(config) ? CRLF.TEXT_CRLF : CRLF.TEXT_INPUT;
		if (action === CRLF.UNDEFINED) action = config.autocrlf === true ? CRLF.AUTO_CRLF : config.autocrlf === "input" ? CRLF.AUTO_INPUT : CRLF.BINARY;
		return action;
	}

	const isAuto = (action) => action === CRLF.AUTO || action === CRLF.AUTO_INPUT || action === CRLF.AUTO_CRLF;

	/** convert.c output_eol is CRLF. */
	const outputsCrlf = (ctx, action) => action === CRLF.TEXT_CRLF || action === CRLF.AUTO_CRLF || (action === CRLF.AUTO && eolIsCrlf(ctx.config));

	/** convert.c gather_stats. */
	function gatherStats(data) {
		const s = { nul: 0, lonecr: 0, lonelf: 0, crlf: 0, printable: 0, nonprintable: 0 };
		for (let i = 0; i < data.length; i++) {
			const c = data[i];
			if (c === 13) {
				if (i + 1 < data.length && data[i + 1] === 10) {
					s.crlf++;
					i++;
				} else s.lonecr++;
				continue;
			}
			if (c === 10) {
				s.lonelf++;
				continue;
			}
			if (c === 127) s.nonprintable++;
			else if (c < 32) {
				if (c === 8 || c === 9 || c === 27 || c === 12) s.printable++;
				else if (c === 0) {
					s.nul++;
					s.nonprintable++;
				} else s.nonprintable++;
			} else s.printable++;
		}
		if (data.length >= 1 && data[data.length - 1] === 0x1a) s.nonprintable--;
		return s;
	}

	const statsBinary = (s) => s.lonecr > 0 || s.nul > 0 || (s.printable >> 7) < s.nonprintable;

	/** convert.c has_crlf_in_index: whether the index blob of `name` has a CR. */
	function crlfInIndex(ctx, name) {
		const index = ctx.index;
		if (!index) return false;
		let pos = indexPos(index.entries, name, 0);
		if (pos < 0) pos = indexPos(index.entries, name, 2);
		if (pos < 0) return false;
		const obj = ctx.db.read(index.entries[pos].oid);
		return obj !== null && obj.type === "blob" && obj.data.includes(13);
	}

	/**
	 * convert.c convert_to_git for CHECKIN: the bytes to hash and store.
	 * @param {boolean} warn - whether to run the safecrlf checks (a real add rather than a stat refresh).
	 */
	function convertToGit(ctx, name, data, warn) {
		const attrs = attrsFor(ctx, ctx.index, name);
		const filter = attrs.get("filter");
		if (typeof filter === "string" && ctx.config.filterDrivers.has(filter)) unsupported(`filter driver ${filter}`);
		const encoding = attrs.get("working-tree-encoding");
		if (encoding === true || encoding === false) die("true/false are no valid working-tree-encodings");
		if (typeof encoding === "string" && encoding !== "" && !/^utf-?8$/i.test(encoding)) unsupported(`working-tree-encoding ${encoding}`);
		const action = crlfAction(ctx, attrs);
		let out = data;
		if (action !== CRLF.BINARY && data.length) {
			const stats = gatherStats(data);
			let convert = stats.crlf > 0;
			const skip = isAuto(action) && statsBinary(stats);
			if (!skip) {
				if (isAuto(action) && crlfInIndex(ctx, name)) convert = false;
				if (warn && ctx.config.safecrlf !== "none") {
					const after = { ...stats };
					if (convert) {
						after.lonelf += after.crlf;
						after.crlf = 0;
					}
					if (outputsCrlf(ctx, action) && after.lonelf && !(isAuto(action) && (after.lonecr || after.crlf || statsBinary(after)))) {
						after.crlf += after.lonelf;
						after.lonelf = 0;
					}
					const die_ = ctx.config.safecrlf === "die";
					if (stats.crlf && !after.crlf) {
						if (die_) die(`CRLF would be replaced by LF in ${name}`);
						ctx.err(`warning: in the working copy of '${name}', CRLF will be replaced by LF the next time Git touches it\n`);
					} else if (stats.lonelf && !after.lonelf) {
						if (die_) die(`LF would be replaced by CRLF in ${name}`);
						ctx.err(`warning: in the working copy of '${name}', LF will be replaced by CRLF the next time Git touches it\n`);
					}
				}
				if (convert) {
					const buf = new Uint8Array(data.length);
					let n = 0;
					for (let i = 0; i < data.length; i++) {
						const c = data[i];
						if (c === 13 && (isAuto(action) || (i + 1 < data.length && data[i + 1] === 10))) continue;
						buf[n++] = c;
					}
					out = buf.subarray(0, n);
				}
			}
		}
		const ident = attrs.get("ident");
		if (ident === true && /\$Id[:$]/.test(stringOf(out))) unsupported("ident attribute with $Id$");
		return out;
	}

	// --- pathspecs (pathspec.c, dir.c) --------------------------------------

	/** setup.c verify_path with core.protectHFS and core.protectNTFS: names git refuses. */
	function badPath(name) {
		for (let part of name.split("/")) {
			if (part === "" || part === "." || part === "..") return true;
			try { part = fromBytes(part); } catch { /* keep the bytes */ }
			const folded = part.replace(/[‌-‏‪-‮⁪-⁯﻿]/g, "").toLowerCase();
			if (folded === ".git" || /^\.git[ .]*$/.test(folded) || /^git~1[ .]*$/.test(folded) || folded.startsWith(".git:")) return true;
		}
		return false;
	}

	/** Whether a repository path has a symbolic link among its leading directories. */
	function symlinkLeading(ctx, name) {
		let at = name.indexOf("/");
		while (at >= 0) {
			const st = ctx.host.lstat(workPath(ctx, name.slice(0, at)));
			if (!st) return false;
			if (isLnk(st.mode)) return true;
			if (!isDir(st.mode)) return false;
			at = name.indexOf("/", at + 1);
		}
		return false;
	}

	/** pathspec.c die_path_inside_submodule and the symlink check for one literal path. */
	function checkLiteralPath(ctx, index, original, path) {
		if (symlinkLeading(ctx, path)) die(`pathspec '${original}' is beyond a symbolic link`);
		for (const entry of index.entries) {
			if (isGitlink(entry.mode) && path.length > entry.name.length && path[entry.name.length] === "/" && path.startsWith(entry.name)) {
				die(`Pathspec '${original}' is in submodule '${entry.name}'`);
			}
		}
	}

	/**
	 * The add pathspec: the whole tree minus literal excludes.
	 * @returns {string[]} the excluded paths.
	 */
	function parseAddPathspec(ctx, index, args) {
		const excludes = [];
		for (const arg of args.length ? args : ["."]) {
			if (arg === "." || arg === ":/") continue;
			const m = /^:\(exclude\)(.*)$/.exec(arg);
			if (!m) unsupported(`pathspec ${arg}`);
			if (!isNormalPath(m[1]) || hasGlob(m[1])) unsupported(`pathspec ${arg}`);
			checkLiteralPath(ctx, index, arg, m[1]);
			excludes.push(m[1]);
		}
		return excludes;
	}

	const excludedBy = (excludes, name) => excludes.some((p) => name === p || name.startsWith(`${p}/`));

	// --- add (builtin/add.c, dir.c, read-cache.c) ---------------------------

	/** read-cache.c index_file_exists: any stage. */
	function inIndex(index, name) {
		const pos = indexPos(index.entries, name, 0);
		if (pos >= 0) return true;
		const at = -pos - 1;
		return at < index.entries.length && index.entries[at].name === name;
	}

	/** dir.c directory_exists_in_index. */
	function dirInIndex(index, dir) {
		let pos = indexPos(index.entries, dir, 0);
		if (pos < 0) pos = -pos - 1;
		for (; pos < index.entries.length; pos++) {
			const name = index.entries[pos].name;
			if (!name.startsWith(dir)) break;
			const end = name.charCodeAt(dir.length);
			if (end > 0x2f) break;
			if (end === 0x2f) return "directory";
			if (Number.isNaN(end) && isGitlink(index.entries[pos].mode)) return "gitdir";
		}
		return "none";
	}

	/** dir.c is_nonbare_repository_dir. */
	function nonbareRepository(ctx, dir) {
		const found = readGitfile(ctx.host, `${dir}/.git`, ctx.env);
		if (found.code === GITFILE.OK || found.code === GITFILE.OPEN_FAILED || found.code === GITFILE.READ_FAILED) return true;
		return found.code === GITFILE.IS_A_DIR && isGitDirectory(ctx.host, `${dir}/.git`, ctx.env);
	}

	const dtypeOf = (st) => (isDir(st.mode) ? Match.DT_DIR : isReg(st.mode) ? Match.DT_REG : isLnk(st.mode) ? Match.DT_LNK : 1);

	/** Names of a directory as repository byte strings. */
	function readNames(ctx, dir) {
		let names;
		try { names = ctx.host.readdir(dir === "" ? ctx.repo.worktree : workPath(ctx, dir)); } catch (error) {
			if (missing(error) || error.code === "EACCES" || error.code === "EPERM") return [];
			throw error;
		}
		return names.map((name) => toBytes(ctx.config.precompose ? name.normalize("NFC") : name));
	}

	/**
	 * dir.c fill_directory with DIR_COLLECT_IGNORED, over the original index.
	 * @returns {{entries: string[], ignored: string[]}}
	 */
	function untracked(ctx, index, excludes) {
		const out = { entries: [], ignored: [] };
		const ex = excludesOf(ctx);
		const gitdirReal = ctx.host.realpath(ctx.repo.gitdir);
		const walk = (dir) => {
			for (const base of readNames(ctx, dir)) {
				if (base === "." || base === ".." || base === ".git") continue;
				const path = dir === "" ? base : `${dir}/${base}`;
				const st = ctx.host.lstat(workPath(ctx, path));
				if (!st) continue;
				const dtype = dtypeOf(st);
				if (dtype !== Match.DT_DIR && inIndex(index, path)) continue;
				if (ex.excluded(path, dtype)) {
					const leading = excludes.some((p) => p === path || (p.length > path.length && p[path.length] === "/" && p.startsWith(path)));
					if (leading && !inIndex(index, path)) out.ignored.push(path);
					continue;
				}
				if (dtype === Match.DT_REG || dtype === Match.DT_LNK) {
					if (!excludedBy(excludes, path) && !inIndex(index, path)) out.entries.push(path);
				} else if (dtype === Match.DT_DIR) {
					const status = dirInIndex(index, path);
					if (status === "directory") walk(path);
					else if (status === "none") {
						if (excludedBy(excludes, path)) continue;
						const host = workPath(ctx, path);
						if (nonbareRepository(ctx, host) && ctx.host.realpath(host) !== gitdirReal) out.entries.push(`${path}/`);
						else walk(path);
					}
				}
			}
		};
		walk("");
		const byBytes = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
		out.entries.sort(byBytes);
		out.ignored.sort(byBytes);
		return out;
	}

	/** read-cache.c add_index_entry with OK_TO_ADD and OK_TO_REPLACE. */
	function addIndexEntry(index, entry) {
		const { entries } = index;
		let pos = indexPos(entries, entry.name, entry.stage);
		index.changed = true;
		if (pos >= 0) {
			entries[pos] = entry;
			return;
		}
		pos = -pos - 1;
		if (entry.stage === 0) while (pos < entries.length && entries[pos].name === entry.name) entries.splice(pos, 1);
		if (badPath(entry.name)) unsupported(`invalid path '${entry.name}'`);
		for (let i = entries.length - 1; i >= 0; i--) {
			const e = entries[i];
			if (e.stage === entry.stage && (entry.name.startsWith(`${e.name}/`) || e.name.startsWith(`${entry.name}/`))) entries.splice(i, 1);
		}
		pos = -indexPos(entries, entry.name, entry.stage) - 1;
		entries.splice(pos, 0, entry);
	}

	/** read-cache.c remove_file_from_index: every stage of a name. */
	function removeIndexName(index, name) {
		let pos = indexPos(index.entries, name, 0);
		if (pos < 0) pos = -pos - 1;
		while (pos < index.entries.length && index.entries[pos].name === name) {
			index.entries.splice(pos, 1);
			index.changed = true;
		}
	}

	/** read-cache.c add_to_index: 0, or -1 after printing an error. */
	function addToIndex(ctx, index, path, st) {
		const { host } = ctx;
		if (!isReg(st.mode) && !isLnk(st.mode) && !isDir(st.mode)) {
			ctx.err(`error: ${path}: can only add regular files, symbolic links or git-directories\n`);
			return -1;
		}
		const host_ = workPath(ctx, path.replace(/\/+$/, ""));
		let name = path;
		let gitlinkHead = null;
		if (isDir(st.mode)) {
			gitlinkHead = nestedHead(ctx, host_);
			if (gitlinkHead === null) {
				ctx.err(`error: '${path}' does not have a commit checked out\nerror: unable to index file '${path}'\n`);
				return -1;
			}
			name = name.replace(/\/+$/, "");
		}
		let pos = indexPos(index.entries, name, 0);
		if (pos < 0 && -pos - 1 < index.entries.length && index.entries[-pos - 1].name === name) pos = -pos - 1;
		const existing = pos >= 0 ? index.entries[pos] : null;
		const mode = modeFromStat(ctx.config, existing, st);
		if (existing && existing.stage === 0 && !entryChanged(ctx, index, existing, st)) return 0;
		let oid;
		if (isReg(st.mode)) {
			let data;
			try { data = host.read(host_); } catch (error) {
				ctx.err(`error: open("${path}"): ${strerror(error)}\nerror: unable to index file '${path}'\n`);
				return -1;
			}
			oid = ctx.db.write("blob", convertToGit(ctx, name, data, true));
		} else if (isLnk(st.mode)) {
			let target;
			try { target = toBytes(host.readlink(host_)); } catch (error) {
				ctx.err(`error: readlink("${path}"): ${strerror(error)}\nerror: unable to index file '${path}'\n`);
				return -1;
			}
			oid = ctx.db.write("blob", bytesOf(target));
		} else oid = gitlinkHead;
		addIndexEntry(index, { name, mode, oid, stage: 0, stat: statBytes(st) });
		return 0;
	}

	/** read-cache.c add_file_to_index. */
	function addFileToIndex(ctx, index, path) {
		let st;
		try { st = ctx.host.fs.lstatSync(workPath(ctx, path.replace(/\/+$/, ""))); } catch (error) {
			die(`unable to stat '${path}': ${strerror(error)}`);
		}
		return addToIndex(ctx, index, path, st);
	}

	/** diff-lib.c check_removed: 1 removed, -1 error, 0 present. */
	function checkRemoved(ctx, entry) {
		let st;
		try { st = ctx.host.fs.lstatSync(workPath(ctx, entry.name)); } catch (error) {
			return missing(error) ? { state: 1 } : { state: -1, error };
		}
		if (symlinkLeading(ctx, entry.name)) return { state: 1 };
		if (isDir(st.mode) && !isGitlink(entry.mode) && nestedHead(ctx, workPath(ctx, entry.name)) === null) return { state: 1 };
		return { state: 0, st };
	}

	/** advice.c advise_if_enabled. */
	function advise(ctx, key, text) {
		const { show, instruction } = ctx.config.advice(key);
		if (!show) return;
		if (instruction) text += `\nDisable this message with "git config set advice.${key} false"`;
		for (const line of text.split("\n")) ctx.err(line === "" ? "hint:\n" : `hint: ${line}\n`);
	}

	const EMBEDDED_ADVICE = (name) => `You've added another git repository inside your current repository.
	Clones of the outer repository will not contain the contents of
	the embedded repository and will not know how to obtain it.
	If you meant to add a submodule, use:

	\tgit submodule add <url> ${name}

	If you added this path by mistake, you can remove it from the
	index with:

	\tgit rm --cached ${name}

	See "git help submodule" for more information.`;

	/** `git add --all --ignore-errors [-- <pathspec>...]`. */
	function cmdAdd(ctx, args) {
		if (args[0] === "--") args = args.slice(1);
		checkWriteTargets(ctx, null);
		const file = indexFileOf(ctx);
		const lock = takeLock(ctx, file);
		const index = readIndexFile(ctx, file);
		ctx.index = index;
		if (ctx.config.hasSubmoduleConfig() && index.entries.some((e) => isGitlink(e.mode))) unsupported("submodule configuration");
		const excludes = parseAddPathspec(ctx, index, args);
		checkWriteTargets(ctx, excludes);
		openObjects(ctx);
		const dir = untracked(ctx, { entries: index.entries.slice() }, excludes);
		let status = 0;
		// diff-files over the matching entries, then update_callback on the queue.
		const actions = [];
		for (let i = 0; i < index.entries.length; i++) {
			const entry = index.entries[i];
			if (excludedBy(excludes, entry.name)) continue;
			if (entry.stage) {
				let end = i;
				while (end + 1 < index.entries.length && index.entries[end + 1].name === entry.name) end++;
				let queued = false;
				for (let k = i; k <= end; k++) {
					const removed = checkRemoved(ctx, index.entries[k]);
					if (removed.state < 0) {
						ctx.err(`${entry.name}: ${strerror(removed.error)}\n`);
						continue;
					}
					if (!queued) actions.push({ name: entry.name, remove: removed.state === 1 });
					queued = true;
					break;
				}
				i = end;
				continue;
			}
			const removed = checkRemoved(ctx, entry);
			if (removed.state < 0) {
				ctx.err(`${entry.name}: ${strerror(removed.error)}\n`);
				continue;
			}
			if (removed.state === 1) actions.push({ name: entry.name, remove: true });
			else if (entryChanged(ctx, index, entry, removed.st)) actions.push({ name: entry.name, remove: false });
		}
		for (const action of actions) {
			if (action.remove) removeIndexName(index, action.name);
			else if (addFileToIndex(ctx, index, action.name)) status = 1;
		}
		if (dir.ignored.length) {
			ctx.err("The following paths are ignored by one of your .gitignore files:\n");
			for (const name of dir.ignored) ctx.err(`${name}\n`);
			advise(ctx, "addIgnoredFile", "Use -f if you really want to add them.");
			status = 1;
		}
		let advised = false;
		for (const path of dir.entries) {
			if (addFileToIndex(ctx, index, path)) {
				status = 1;
				continue;
			}
			if (!path.endsWith("/")) continue;
			const name = path.slice(0, -1);
			ctx.err(`warning: adding embedded git repository: ${name}\n`);
			if (!advised) advise(ctx, "addEmbeddedRepo", EMBEDDED_ADVICE(name));
			advised = true;
		}
		if (index.changed) commitIndex(ctx, file, lock, index.entries);
		return status;
	}

	// --- write-tree (cache-tree.c) -------------------------------------------

	const modeText = (mode) => (isDir(mode) ? "40000" : mode.toString(8));

	/** cache-tree.c update_one over sorted stage-0 entries below `base`. */
	function buildTree(ctx, entries, base, start) {
		const parts = [];
		let i = start, length = 0;
		while (i < entries.length && entries[i].name.startsWith(base)) {
			const entry = entries[i];
			const rest = entry.name.slice(base.length);
			const slash = rest.indexOf("/");
			let name, mode, oid;
			if (slash >= 0) {
				name = rest.slice(0, slash);
				const sub = buildTree(ctx, entries, `${base}${name}/`, i);
				mode = S_IFDIR;
				oid = sub.oid;
				i = sub.end;
			} else {
				name = rest;
				mode = entry.mode;
				oid = entry.oid;
				if (!isGitlink(mode) && !ctx.db.has(oid)) {
					throw new GitExit(128, `error: invalid object ${mode.toString(8).padStart(6, "0")} ${oid} for '${entry.name}'\nfatal: git-write-tree: error building trees\n`);
				}
				i++;
			}
			const head = bytesOf(`${modeText(mode)} ${name}\0`);
			const part = new Uint8Array(head.length + 20);
			part.set(head);
			part.set(rawOf(oid), head.length);
			parts.push(part);
			length += part.length;
		}
		const data = new Uint8Array(length);
		let at = 0;
		for (const part of parts) {
			data.set(part, at);
			at += part.length;
		}
		return { oid: ctx.db.write("tree", data), end: i };
	}

	/** `git write-tree`. */
	function cmdWriteTree(ctx) {
		checkWriteTargets(ctx, null);
		const file = indexFileOf(ctx);
		takeLock(ctx, file);
		const index = readIndexFile(ctx, file);
		const unmerged = index.entries.filter((e) => e.stage);
		if (unmerged.length) {
			let text = "";
			for (let n = 0; n < unmerged.length; n++) {
				if (n === 10) {
					text += "...\n";
					break;
				}
				text += `${unmerged[n].name}: unmerged (${unmerged[n].oid})\n`;
			}
			throw new GitExit(128, `${text}fatal: git-write-tree: error building trees\n`);
		}
		openObjects(ctx);
		ctx.out(`${buildTree(ctx, index.entries, "", 0).oid}\n`);
		return 0;
	}

	// --- object readers (ls-tree, cat-file) --------------------------------

	/** Entry of `path` in a tree, descending through subtrees, or null. */
	function treeEntry(ctx, tree, path) {
		const parts = path.split("/");
		let data = tree;
		for (let k = 0; k < parts.length; k++) {
			const entry = parseTree(data).find((e) => e.name === parts[k]);
			if (!entry) return null;
			if (k === parts.length - 1) return entry;
			if (!isDir(entry.mode)) return null;
			const obj = ctx.db.read(entry.oid);
			if (!obj || obj.type !== "tree") return null;
			data = obj.data;
		}
		return null;
	}

	const typeOfMode = (mode) => (isDir(mode) ? "tree" : isGitlink(mode) ? "commit" : "blob");

	/** `git ls-tree -z -l <tree> -- <path>` with literal pathspecs. */
	function cmdLsTree(ctx, tree, path) {
		if (!OID.test(tree)) unsupported(`ls-tree of ${tree}`);
		if (!isNormalPath(path) || (!ctx.env.literal && hasGlob(path))) unsupported(`ls-tree path ${path}`);
		openObjects(ctx);
		const peeled = peel(ctx.db, tree, "tree");
		if (!peeled) die("not a tree object");
		const entry = treeEntry(ctx, peeled.data, path);
		if (!entry) return 0;
		let size = "-";
		if (!isDir(entry.mode) && !isGitlink(entry.mode)) {
			const obj = ctx.db.read(entry.oid);
			if (!obj) die(`could not get object info about '${entry.oid}'`);
			size = String(obj.data.length);
		}
		ctx.out(`${entry.mode.toString(8).padStart(6, "0")} ${typeOfMode(entry.mode)} ${entry.oid} ${size.padStart(7)}\t${path}\0`);
		return 0;
	}

	/** `git cat-file blob <oid>`. */
	function cmdCatFile(ctx, oid) {
		if (!OID.test(oid)) unsupported(`cat-file of ${oid}`);
		openObjects(ctx);
		const blob = peel(ctx.db, oid, "blob");
		if (!blob) die(`git cat-file ${oid}: bad file`);
		ctx.out(stringOf(blob.data));
		return 0;
	}

	// --- index readers (ls-files, check-ignore) -----------------------------

	/** `git ls-files -z --stage`. */
	function cmdLsFiles(ctx) {
		const index = readIndexFile(ctx, indexFileOf(ctx));
		for (const e of index.entries) ctx.out(`${e.mode.toString(8).padStart(6, "0")} ${e.oid} ${e.stage}\t${e.name}\0`);
		return 0;
	}

	/** `git check-ignore -z --stdin`. */
	function cmdCheckIgnore(ctx, stdin) {
		const index = readIndexFile(ctx, indexFileOf(ctx));
		ctx.index = index;
		const records = stdin.split("\0");
		if (records.length && records[records.length - 1] === "") records.pop();
		const ex = excludesOf(ctx);
		let ignored = 0;
		for (const path of records) {
			if (path === "" || path.startsWith(":") || !isNormalPath(path) || hasGlob(path)) unsupported(`check-ignore path ${JSON.stringify(path)}`);
			checkLiteralPath(ctx, index, path, path);
			let pos = indexPos(index.entries, path, 0);
			if (pos < 0) pos = -pos - 1;
			const seen = pos < index.entries.length && (index.entries[pos].name === path || index.entries[pos].name.startsWith(`${path}/`));
			if (seen) continue;
			const st = ctx.host.lstat(workPath(ctx, path));
			const hit = ex.matching(path, st ? dtypeOf(st) : Match.DT_UNKNOWN);
			if (!hit || hit.flags & Match.FLAG_NEGATIVE) continue;
			ctx.out(`${path}\0`);
			ignored++;
		}
		return ignored ? 0 : 1;
	}

	// --- rev-parse (builtin/rev-parse.c) -----------------------------------

	/** `git rev-parse --show-toplevel --absolute-git-dir --git-path objects`. */
	function cmdRevParse(ctx) {
		const { repo, host } = ctx;
		if (repo.worktree === null) die("this operation must be run in a work tree");
		ctx.out(`${toBytes(host.realpath(repo.worktree) ?? repo.worktree)}\n`);
		ctx.out(`${toBytes(host.realpath(repo.gitdir) ?? repo.gitdir)}\n`);
		let objects;
		if (repo.linked) objects = `${repo.common}/objects`;
		else if (repo.dotGit) objects = relativePath(".git/objects", repo.prefix);
		else objects = `${repo.gitdir}/objects`;
		ctx.out(`${toBytes(objects)}\n`);
		return 0;
	}

	// --- diff-tree (tree-diff.c, diffcore-rename.c, diff.c) ----------------

	/** tree-diff.c base_name_compare, a directory comparing as name + '/'. */
	function baseNameCompare(a, b) {
		const len = Math.min(a.name.length, b.name.length);
		const head = a.name.slice(0, len), other = b.name.slice(0, len);
		if (head !== other) return head < other ? -1 : 1;
		const c1 = len < a.name.length ? a.name.charCodeAt(len) : isDir(a.mode) ? 0x2f : 0;
		const c2 = len < b.name.length ? b.name.charCodeAt(len) : isDir(b.mode) ? 0x2f : 0;
		return c1 - c2;
	}

	/** Tree entries of a tree object id, sorted as stored. */
	function treeOf(ctx, oid) {
		const obj = ctx.db.read(oid);
		if (!obj) die(`unable to read tree (${oid})`);
		if (obj.type !== "tree") unsupported(`tree ${oid} is a ${obj.type}`);
		return parseTree(obj.data);
	}

	/** tree-diff.c ll_diff_tree_paths with -r: the filepair queue. */
	function diffTrees(ctx, a, b, base, queue) {
		const x = a === null ? [] : treeOf(ctx, a), y = b === null ? [] : treeOf(ctx, b);
		let i = 0, j = 0;
		const side = (e) => ({ path: base + e.name, mode: e.mode, oid: e.oid });
		const emit = (one, two) => {
			const e = one ?? two;
			if (isDir(e.mode)) diffTrees(ctx, one ? one.oid : null, two ? two.oid : null, `${base}${e.name}/`, queue);
			else queue.push({ one: one ? side(one) : null, two: two ? side(two) : null });
		};
		while (i < x.length || j < y.length) {
			const cmp = i >= x.length ? 1 : j >= y.length ? -1 : baseNameCompare(x[i], y[j]);
			if (cmp < 0) emit(x[i++], null);
			else if (cmp > 0) emit(null, y[j++]);
			else {
				const p = x[i++], t = y[j++];
				if (p.oid === t.oid && p.mode === t.mode) continue;
				if (isDir(p.mode) && isDir(t.mode)) diffTrees(ctx, p.oid, t.oid, `${base}${p.name}/`, queue);
				else queue.push({ one: side(p), two: side(t) });
			}
		}
		return queue;
	}

	const MAX_SCORE = 60000, MIN_SCORE = 30000, BASENAME_SCORE = 45000;
	const basenameOf = (path) => path.slice(path.lastIndexOf("/") + 1);

	/** The bytes of a filespec, as diff.c diff_populate_filespec gives them. */
	function specData(ctx, spec) {
		if (spec.data) return spec.data;
		if (isGitlink(spec.mode)) spec.data = bytesOf(`Subproject commit ${spec.oid}\n`);
		else {
			const obj = ctx.db.read(spec.oid);
			if (!obj) die(`unable to read ${spec.oid}`);
			spec.data = obj.data;
		}
		return spec.data;
	}

	/** diff.c diff_filespec_is_binary. */
	function specBinary(ctx, spec, valid = true) {
		if (spec.binary !== undefined) return spec.binary;
		const value = attrsFor(ctx, ctx.index, spec.path).get("diff");
		let driver = -1;
		if (value === true) driver = 0;
		else if (value === false) driver = 1;
		else driver = ctx.config.diffBinary(typeof value === "string" ? value : "default");
		if (driver !== -1) spec.binary = driver === 1;
		else if (!valid) spec.binary = false;
		else {
			const data = specData(ctx, spec);
			spec.binary = (!isGitlink(spec.mode) && data.length > ctx.config.bigFileThreshold) || data.subarray(0, 8000).includes(0);
		}
		return spec.binary;
	}

	/** diffcore-delta.c hash_chars: byte counts per span hash. */
	function spanCounts(ctx, spec) {
		if (spec.counts) return spec.counts;
		const data = specData(ctx, spec);
		const text = !specBinary(ctx, spec);
		const counts = new Map();
		let a1 = 0, a2 = 0, n = 0;
		const add = () => {
			const hash = ((a1 + Math.imul(a2, 0x61)) >>> 0) % 107927;
			counts.set(hash, (counts.get(hash) ?? 0) + n);
			n = 0;
			a1 = a2 = 0;
		};
		for (let i = 0; i < data.length; i++) {
			const c = data[i];
			if (text && c === 13 && i + 1 < data.length && data[i + 1] === 10) continue;
			const old = a1;
			a1 = (((a1 << 7) ^ (a2 >>> 25)) + c) >>> 0;
			a2 = ((a2 << 7) ^ (old >>> 25)) >>> 0;
			if (++n < 64 && c !== 10) continue;
			add();
		}
		if (n > 0) add();
		spec.counts = counts;
		return counts;
	}

	/** diffcore-rename.c estimate_similarity. */
	function similarity(ctx, src, dst, minimum) {
		if (!isReg(src.mode) || !isReg(dst.mode)) return 0;
		const a = specData(ctx, src).length, b = specData(ctx, dst).length;
		const max = Math.max(a, b), base = Math.min(a, b);
		if (max * (MAX_SCORE - minimum) < (max - base) * MAX_SCORE) return 0;
		const s = spanCounts(ctx, src), d = spanCounts(ctx, dst);
		let copied = 0;
		for (const [hash, count] of s) {
			const other = d.get(hash);
			if (other !== undefined) copied += Math.min(count, other);
		}
		if (!b) return 0;
		return Math.floor((copied * MAX_SCORE) / max);
	}

	/** diffcore-rename.c score_compare. */
	function scoreCompare(a, b) {
		if (a.dst === -1) return b.dst !== -1 ? 1 : 0;
		if (b.dst === -1) return -1;
		if (a.score === b.score) return b.nameScore - a.nameScore;
		return b.score - a.score;
	}

	/** diffcore-rename.c diffcore_rename for -M: rewrites the queue. */
	function detectRenames(ctx, queue) {
		const dsts = [], srcs = [];
		for (const p of queue) {
			if (!p.one && p.two) dsts.push({ p, rename: null });
			else if (p.one && !p.two) srcs.push(p.one);
		}
		if (!dsts.length || !srcs.length) return queue;
		for (const src of srcs) src.used = 0;
		const record = (dst, src, score) => {
			dst.rename = { one: src, two: dst.p.two, score };
			src.used++;
		};
		// Exact renames: candidates in source order, unused ones first.
		const byOid = new Map();
		for (const src of srcs) {
			if (!byOid.has(src.oid)) byOid.set(src.oid, []);
			byOid.get(src.oid).push(src);
		}
		for (const dst of dsts) {
			const target = dst.p.two;
			let best = null, bestScore = -1, budget = 100;
			for (const src of byOid.get(target.oid) ?? []) {
				if ((!isReg(src.mode) || !isReg(target.mode)) && src.mode !== target.mode) continue;
				if (src.used) continue;
				const score = 1 + (basenameOf(src.path) === basenameOf(target.path) ? 1 : 0);
				if (score > bestScore) {
					best = src;
					bestScore = score;
					if (score === 2) break;
				}
				if (!--budget) break;
			}
			if (best) record(dst, best, MAX_SCORE);
		}
		let sources = srcs.filter((s) => !s.used);
		// Basename matches among the remaining unique basenames.
		const uniq = (items, nameOf) => {
			const map = new Map();
			items.forEach((item, k) => map.set(nameOf(item), map.has(nameOf(item)) ? -1 : k));
			return map;
		};
		const open = dsts.filter((d) => !d.rename);
		const srcNames = uniq(sources, (s) => basenameOf(s.path));
		const dstNames = uniq(open, (d) => basenameOf(d.p.two.path));
		for (let k = 0; k < sources.length; k++) {
			const base = basenameOf(sources[k].path);
			if (!dstNames.has(base)) continue;
			const si = srcNames.get(base), di = dstNames.get(base);
			if (si === -1 || di === -1) continue;
			const dst = open[di];
			if (dst.rename) continue;
			const score = similarity(ctx, sources[si], dst.p.two, BASENAME_SCORE);
			if (score < BASENAME_SCORE) continue;
			record(dst, sources[si], score);
		}
		sources = sources.filter((s) => !s.used);
		const remaining = dsts.filter((d) => !d.rename);
		if (remaining.length && sources.length) {
			const limit = ctx.config.renameLimit;
			if (limit > 0 && remaining.length * sources.length > limit * limit) {
				ctx.renameLimit = Math.max(remaining.length, sources.length);
			} else {
				const mx = [];
				for (const dst of remaining) {
					const m = [0, 1, 2, 3].map(() => ({ dst: -1, src: -1, score: 0, nameScore: 0 }));
					for (const src of sources) {
						const candidate = {
							dst,
							src,
							score: similarity(ctx, src, dst.p.two, MIN_SCORE),
							nameScore: basenameOf(src.path) === basenameOf(dst.p.two.path) ? 1 : 0,
						};
						let worst = 0;
						for (let w = 1; w < 4; w++) if (scoreCompare(m[w], m[worst]) > 0) worst = w;
						if (scoreCompare(m[worst], candidate) > 0) m[worst] = candidate;
					}
					mx.push(...m);
				}
				mx.sort(scoreCompare);
				for (const c of mx) {
					if (c.dst === -1 || c.score < MIN_SCORE) break;
					if (c.dst.rename || c.src.used) continue;
					record(c.dst, c.src, c.score);
				}
			}
		}
		const renamed = new Map(dsts.filter((d) => d.rename).map((d) => [d.p, d.rename]));
		const out = [];
		for (const p of queue) {
			if (!p.one) out.push(renamed.get(p) ?? p);
			else if (!p.two) {
				if (!p.one.used) out.push(p);
			} else out.push(p);
		}
		return out;
	}

	/** diff.c builtin_diffstat and show_numstat with -z. */
	function numstat(ctx, p) {
		const one = p.one ?? { path: p.two.path, mode: 0, oid: null }, two = p.two ?? { path: p.one.path, mode: 0, oid: null };
		const binary = specBinary(ctx, one, p.one !== null) || specBinary(ctx, two, p.two !== null);
		const same = p.one && p.two && p.one.oid === p.two.oid;
		let text;
		if (binary) text = "-\t-\t";
		else {
			let added = 0, deleted = 0;
			if (!same) {
				const a = p.one ? specData(ctx, p.one) : new Uint8Array(0), b = p.two ? specData(ctx, p.two) : new Uint8Array(0);
				({ added, deleted } = Xdiff.numstat(a, b));
				if (p.one && p.two && !added && !deleted && !isGitlink(p.one.mode) && !isGitlink(p.two.mode)) return;
			}
			text = `${added}\t${deleted}\t`;
		}
		if (p.one && p.two && p.one.path !== p.two.path) ctx.out(`${text}\0${p.one.path}\0${p.two.path}\0`);
		else ctx.out(`${text}${two.path}\0`);
	}

	/** `git diff-tree -r -M -z --numstat <a> <b>`. */
	function cmdDiffTree(ctx, a, b) {
		if (!OID.test(a) || !OID.test(b)) unsupported("diff-tree of a non-hex object name");
		openObjects(ctx);
		const trees = [a, b].map((oid) => {
			if (!ctx.db.has(oid)) die(`bad object ${oid}`);
			const tree = peel(ctx.db, oid, "tree");
			if (!tree) unsupported(`diff-tree of ${oid}`);
			return tree.oid;
		});
		ctx.index = readIndexFile(ctx, indexFileOf(ctx));
		const queue = detectRenames(ctx, diffTrees(ctx, trees[0], trees[1], "", []));
		for (const p of queue) numstat(ctx, p);
		if (ctx.renameLimit) {
			ctx.err("warning: exhaustive rename detection was skipped due to too many files.\n");
			ctx.err(`warning: you may want to set your diff.renameLimit variable to at least ${ctx.renameLimit} and retry the command.\n`);
		}
		return 0;
	}

	// --- entry point -------------------------------------------------------

	const same = (args, expected) => args.length === expected.length && args.every((arg, k) => expected[k] === null || arg === expected[k]);

	/** Dispatch one invocation; returns the exit code. */
	function dispatch(ctx, args, cwd, rawEnv, stdin) {
		const command = args[0];
		ctx.env = gitEnv(rawEnv, cwd, command);
		ctx.repo = openRepo(ctx.host, cwd, ctx.env);
		ctx.config = ctx.repo.config;
		if (command === "rev-parse") {
			if (!same(args, ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-path", "objects"])) unsupported(`rev-parse ${args.slice(1).join(" ")}`);
			return cmdRevParse(ctx);
		}
		if (ctx.repo.worktree === null || ctx.repo.prefix !== "") unsupported(`${command} outside the top of a work tree`);
		if (command === "add" && same(args.slice(0, 3), ["add", "--all", "--ignore-errors"])) return cmdAdd(ctx, args.slice(3));
		if (same(args, ["write-tree"])) return cmdWriteTree(ctx);
		if (same(args, ["ls-tree", "-z", "-l", null, "--", null])) return cmdLsTree(ctx, args[3], args[5]);
		if (same(args, ["cat-file", "blob", null])) return cmdCatFile(ctx, args[2]);
		if (same(args, ["diff-tree", "-r", "-M", "-z", "--numstat", null, null])) return cmdDiffTree(ctx, args[5], args[6]);
		if (same(args, ["ls-files", "-z", "--stage"])) return cmdLsFiles(ctx);
		if (same(args, ["check-ignore", "-z", "--stdin"])) return cmdCheckIgnore(ctx, stdin);
		return unsupported(`git ${args.join(" ")}`);
	}

	const lossy = new TextDecoder("utf-8");

	/**
	 * Run one git invocation of the workspace-changes plugin.
	 * @param {{argv: string[], cwd: string, env?: object, stdin?: string | Uint8Array}} request
	 * @param {object} fs - Node-style synchronous file system.
	 * @returns {{exitCode: number, stdout: Uint8Array, stderr: string}}
	 */
	function run(request, fs) {
		let args = request.argv.slice();
		if (args.length && (args[0] === "git" || args[0].endsWith("/git"))) args = args.slice(1);
		args = args.map(toBytes);
		const stdin = request.stdin === undefined ? "" : typeof request.stdin === "string" ? toBytes(request.stdin) : stringOf(request.stdin);
		let out = "", err = "";
		const ctx = { host: new Host(fs), locks: [], out: (s) => { out += s; }, err: (s) => { err += s; } };
		let exitCode;
		try {
			exitCode = dispatch(ctx, args, request.cwd, request.env ?? {}, stdin);
		} catch (error) {
			if (error instanceof GitExit) {
				exitCode = error.code;
				err += error.stderr;
			} else if (error instanceof Unsupported || error instanceof UnsupportedObjects) {
				exitCode = 128;
				err += `fatal: native git: unsupported: ${error.message}\n`;
			} else {
				exitCode = 128;
				err += `fatal: native git: ${error && error.message ? error.message : String(error)}\n`;
			}
		} finally {
			for (const lock of ctx.locks) {
				try { fs.unlinkSync(lock); } catch { /* already gone */ }
			}
			if (ctx.db) ctx.db.close();
		}
		return { exitCode, stdout: bytesOf(out), stderr: lossy.decode(bytesOf(err)) };
	}

	root.DshNativeGit = { run };

})(globalThis);
