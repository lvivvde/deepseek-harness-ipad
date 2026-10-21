/*
 * Object storage for the native read-only Git of deepseek-harness-ipad.
 *
 * Reads loose objects, packs (index v2, offset and reference deltas) and
 * alternates the way git v2.54.0 lays them out, and writes new loose objects
 * only. SHA-1 object names, a synchronous inflate, and a stored-block deflate
 * are included so the module runs inside a Worker without dependencies.
 *
 * The host file system is node-fs-like and synchronous. Paths handed to it are
 * ordinary strings; paths inside a repository are UTF-8 byte strings, one
 * character per byte, so they sort and compare the way git compares them.
 */
(function (root) {
	"use strict";

	const encoder = new TextEncoder();
	const decoder = new TextDecoder("utf-8", { fatal: true });

	/**
	 * A repository path as a byte string.
	 * @param {string} text - path as the host reports it.
	 * @returns {string} one character per UTF-8 byte.
	 */
	function toBytes(text) {
		const bytes = encoder.encode(text);
		let out = "";
		for (let i = 0; i < bytes.length; i += 0x8000) out += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
		return out;
	}

	/**
	 * A byte string as a host path.
	 * @param {string} bytes - one character per byte.
	 * @returns {string} the decoded path.
	 * @throws when the bytes are not UTF-8.
	 */
	function fromBytes(bytes) {
		return decoder.decode(bytesOf(bytes));
	}

	/**
	 * The bytes of a byte string.
	 * @param {string} text - one character per byte.
	 * @returns {Uint8Array}
	 */
	function bytesOf(text) {
		const out = new Uint8Array(text.length);
		for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i);
		return out;
	}

	/**
	 * A byte range as a byte string.
	 * @param {Uint8Array} data - source.
	 * @param {number} [start] - first byte.
	 * @param {number} [end] - one past the last byte.
	 * @returns {string}
	 */
	function stringOf(data, start = 0, end = data.length) {
		let out = "";
		for (let i = start; i < end; i += 0x8000) out += String.fromCharCode.apply(null, data.subarray(i, Math.min(end, i + 0x8000)));
		return out;
	}

	const HEX = "0123456789abcdef";

	/**
	 * Lowercase hex of a byte range.
	 * @param {Uint8Array} data - source.
	 * @param {number} [start] - first byte.
	 * @param {number} [end] - one past the last byte.
	 * @returns {string}
	 */
	function hexOf(data, start = 0, end = data.length) {
		let out = "";
		for (let i = start; i < end; i++) out += HEX[data[i] >> 4] + HEX[data[i] & 15];
		return out;
	}

	/**
	 * Bytes of a 40-character hex object name.
	 * @param {string} hex - object name.
	 * @returns {Uint8Array}
	 */
	function rawOf(hex) {
		const out = new Uint8Array(hex.length >> 1);
		for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
		return out;
	}

	/** Incremental SHA-1. */
	class Sha1 {
		constructor() {
			this.h = new Int32Array([0x67452301, 0xefcdab89 | 0, 0x98badcfe | 0, 0x10325476, 0xc3d2e1f0 | 0]);
			this.block = new Uint8Array(64);
			this.used = 0;
			this.length = 0;
			this.w = new Int32Array(80);
		}

		/**
		 * Add bytes.
		 * @param {Uint8Array} data - next bytes.
		 * @returns {Sha1} this hash.
		 */
		update(data) {
			let i = 0;
			this.length += data.length;
			if (this.used > 0) {
				const take = Math.min(64 - this.used, data.length);
				this.block.set(data.subarray(0, take), this.used);
				this.used += take;
				i = take;
				if (this.used < 64) return this;
				this.compress(this.block, 0);
				this.used = 0;
			}
			for (; i + 64 <= data.length; i += 64) this.compress(data, i);
			if (i < data.length) {
				this.block.set(data.subarray(i), 0);
				this.used = data.length - i;
			}
			return this;
		}

		/**
		 * Finish the hash.
		 * @returns {Uint8Array} the 20-byte digest.
		 */
		digest() {
			const bits = this.length * 8;
			const tail = new Uint8Array(((this.used + 8) >> 6) * 64 + 64 - this.used);
			tail[0] = 0x80;
			const n = tail.length;
			const high = Math.floor(bits / 0x100000000), low = bits >>> 0;
			tail[n - 8] = high >>> 24; tail[n - 7] = high >>> 16; tail[n - 6] = high >>> 8; tail[n - 5] = high;
			tail[n - 4] = low >>> 24; tail[n - 3] = low >>> 16; tail[n - 2] = low >>> 8; tail[n - 1] = low;
			this.length -= n;
			this.update(tail);
			const out = new Uint8Array(20);
			for (let k = 0; k < 5; k++) {
				out[k * 4] = this.h[k] >>> 24; out[k * 4 + 1] = this.h[k] >>> 16;
				out[k * 4 + 2] = this.h[k] >>> 8; out[k * 4 + 3] = this.h[k];
			}
			return out;
		}

		compress(data, at) {
			const w = this.w;
			for (let t = 0; t < 16; t++) {
				const j = at + t * 4;
				w[t] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | data[j + 3];
			}
			for (let t = 16; t < 80; t++) {
				const x = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16];
				w[t] = (x << 1) | (x >>> 31);
			}
			let a = this.h[0], b = this.h[1], c = this.h[2], d = this.h[3], e = this.h[4];
			for (let t = 0; t < 80; t++) {
				let f, k;
				if (t < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
				else if (t < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
				else if (t < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc | 0; }
				else { f = b ^ c ^ d; k = 0xca62c1d6 | 0; }
				const temp = (((a << 5) | (a >>> 27)) + f + e + k + w[t]) | 0;
				e = d; d = c; c = (b << 30) | (b >>> 2); b = a; a = temp;
			}
			this.h[0] = (this.h[0] + a) | 0; this.h[1] = (this.h[1] + b) | 0; this.h[2] = (this.h[2] + c) | 0;
			this.h[3] = (this.h[3] + d) | 0; this.h[4] = (this.h[4] + e) | 0;
		}
	}

	/**
	 * The name git gives an object.
	 * @param {string} type - blob, tree, commit or tag.
	 * @param {Uint8Array} data - object body.
	 * @returns {string} 40-character hex name.
	 */
	function hashObject(type, data) {
		return hexOf(new Sha1().update(encoder.encode(`${type} ${data.length}\0`)).update(data).digest());
	}

	/** Thrown when compressed input ends early; a pack reader retries with more bytes. */
	class Truncated extends Error {}

	const LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
	const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
	const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
	const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
	const CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

	/**
	 * A lookup table for canonical Huffman codes, indexed by the next `bits`
	 * input bits (least significant first). Each entry is `symbol << 4 | length`.
	 * @param {ArrayLike<number>} lengths - code length per symbol.
	 * @returns {{table: Int32Array, bits: number}}
	 */
	function huffman(lengths) {
		let bits = 0;
		const count = new Array(16).fill(0);
		for (const length of lengths) {
			count[length]++;
			if (length > bits) bits = length;
		}
		count[0] = 0;
		let left = 1;
		for (let len = 1; len < 16; len++) {
			left = (left << 1) - count[len];
			if (left < 0) throw new Error("inflate: oversubscribed code");
		}
		const next = new Array(16).fill(0);
		for (let len = 1, code = 0; len < 16; len++) {
			code = (code + count[len - 1]) << 1;
			next[len] = code;
		}
		const size = 1 << Math.max(bits, 1);
		const table = new Int32Array(size).fill(-1);
		for (let symbol = 0; symbol < lengths.length; symbol++) {
			const len = lengths[symbol];
			if (len === 0) continue;
			let code = next[len]++;
			let reversed = 0;
			for (let i = 0; i < len; i++) { reversed = (reversed << 1) | (code & 1); code >>= 1; }
			for (let i = reversed; i < size; i += 1 << len) table[i] = (symbol << 4) | len;
		}
		return { table, bits: Math.max(bits, 1) };
	}

	let fixedCodes = null;

	/** The fixed literal/length and distance codes. */
	function fixed() {
		if (fixedCodes) return fixedCodes;
		const lengths = new Array(288);
		for (let i = 0; i < 144; i++) lengths[i] = 8;
		for (let i = 144; i < 256; i++) lengths[i] = 9;
		for (let i = 256; i < 280; i++) lengths[i] = 7;
		for (let i = 280; i < 288; i++) lengths[i] = 8;
		fixedCodes = { lit: huffman(lengths), dist: huffman(new Array(30).fill(5)) };
		return fixedCodes;
	}

	/**
	 * Inflate one zlib stream.
	 * @param {Uint8Array} src - input.
	 * @param {number} pos - first byte of the stream.
	 * @param {number} [expected] - exact output size when known.
	 * @returns {{data: Uint8Array, end: number}} output and the position after the checksum.
	 * @throws {Truncated} when the input ends before the stream does.
	 */
	function inflate(src, pos, expected) {
		const end = src.length;
		if (pos + 2 > end) throw new Truncated("inflate: truncated");
		const cmf = src[pos], flg = src[pos + 1];
		if ((cmf & 15) !== 8 || ((cmf << 8) | flg) % 31 !== 0 || (flg & 0x20)) throw new Error("inflate: bad zlib header");
		pos += 2;
		let out = new Uint8Array(expected ?? Math.max(1024, (end - pos) * 3));
		let outLen = 0;
		let bitbuf = 0, bitcnt = 0, over = 0;

		function need(n) {
			while (bitcnt < n) {
				let byte = 0;
				if (pos < end) byte = src[pos];
				else over++;
				pos++;
				bitbuf |= byte << bitcnt;
				bitcnt += 8;
			}
		}
		function take(n) {
			need(n);
			const v = bitbuf & ((1 << n) - 1);
			bitbuf >>>= n;
			bitcnt -= n;
			return v;
		}
		function symbol(code) {
			need(code.bits);
			const e = code.table[bitbuf & ((1 << code.bits) - 1)];
			if (e < 0) fail("inflate: bad code");
			const len = e & 15;
			bitbuf >>>= len;
			bitcnt -= len;
			return e >> 4;
		}
		function checkOver() {
			if (bitcnt < 8 * over) throw new Truncated("inflate: truncated");
		}
		function fail(message) {
			checkOver();
			throw new Error(message);
		}
		function grow(n) {
			if (outLen + n <= out.length) return;
			if (expected !== undefined) fail("inflate: size mismatch");
			let size = out.length * 2;
			while (size < outLen + n) size *= 2;
			const bigger = new Uint8Array(size);
			bigger.set(out.subarray(0, outLen));
			out = bigger;
		}

		let last = 0;
		while (!last) {
			last = take(1);
			const type = take(2);
			if (type === 0) {
				bitbuf = 0;
				pos -= bitcnt >> 3;
				bitcnt = 0;
				if (pos > end) throw new Truncated("inflate: truncated");
				over = 0;
				if (pos + 4 > end) throw new Truncated("inflate: truncated");
				const len = src[pos] | (src[pos + 1] << 8), nlen = src[pos + 2] | (src[pos + 3] << 8);
				if (len !== (~nlen & 0xffff)) fail("inflate: bad stored block");
				pos += 4;
				if (pos + len > end) throw new Truncated("inflate: truncated");
				grow(len);
				out.set(src.subarray(pos, pos + len), outLen);
				outLen += len;
				pos += len;
				continue;
			}
			let lit, dist;
			if (type === 1) ({ lit, dist } = fixed());
			else if (type === 2) {
				const nlen = take(5) + 257, ndist = take(5) + 1, ncode = take(4) + 4;
				const clens = new Array(19).fill(0);
				for (let i = 0; i < ncode; i++) clens[CLEN_ORDER[i]] = take(3);
				checkOver();
				const clen = huffman(clens);
				const lengths = new Array(nlen + ndist).fill(0);
				for (let i = 0; i < nlen + ndist;) {
					const sym = symbol(clen);
					if (sym < 16) { lengths[i++] = sym; continue; }
					let repeat, value = 0;
					if (sym === 16) {
						if (i === 0) fail("inflate: repeat without length");
						value = lengths[i - 1];
						repeat = 3 + take(2);
					} else if (sym === 17) repeat = 3 + take(3);
					else repeat = 11 + take(7);
					if (i + repeat > nlen + ndist) fail("inflate: too many lengths");
					while (repeat--) lengths[i++] = value;
				}
				checkOver();
				if (lengths[256] === 0) fail("inflate: no end code");
				lit = huffman(lengths.slice(0, nlen));
				dist = huffman(lengths.slice(nlen));
			} else fail("inflate: bad block type");
			for (;;) {
				const sym = symbol(lit);
				if (sym < 256) {
					if (outLen >= out.length) { checkOver(); grow(1); }
					out[outLen++] = sym;
					continue;
				}
				if (sym === 256) break;
				const li = sym - 257;
				if (li >= 29) fail("inflate: bad length");
				const length = LEN_BASE[li] + take(LEN_EXTRA[li]);
				const di = symbol(dist);
				if (di >= 30) fail("inflate: bad distance");
				const distance = DIST_BASE[di] + take(DIST_EXTRA[di]);
				checkOver();
				if (distance > outLen) fail("inflate: distance too far");
				grow(length);
				for (let i = 0; i < length; i++, outLen++) out[outLen] = out[outLen - distance];
			}
			checkOver();
		}
		pos -= bitcnt >> 3;
		if (pos + 4 > end) throw new Truncated("inflate: truncated");
		const data = expected === undefined ? out.slice(0, outLen) : out;
		if (expected !== undefined && outLen !== expected) fail("inflate: size mismatch");
		const sum = ((src[pos] << 24) | (src[pos + 1] << 16) | (src[pos + 2] << 8) | src[pos + 3]) >>> 0;
		if (sum !== adler32(data)) throw new Error("inflate: checksum mismatch");
		return { data, end: pos + 4 };
	}

	/**
	 * The Adler-32 checksum zlib appends.
	 * @param {Uint8Array} data - input.
	 * @returns {number}
	 */
	function adler32(data) {
		let a = 1, b = 0;
		for (let i = 0; i < data.length;) {
			const stop = Math.min(data.length, i + 3800);
			for (; i < stop; i++) { a += data[i]; b += a; }
			a %= 65521;
			b %= 65521;
		}
		return ((b << 16) | a) >>> 0;
	}

	/**
	 * A zlib stream of stored blocks, which git reads like any other.
	 * @param {Uint8Array} data - input.
	 * @returns {Uint8Array}
	 */
	function deflateStored(data) {
		const blocks = Math.max(1, Math.ceil(data.length / 65535));
		const out = new Uint8Array(2 + blocks * 5 + data.length + 4);
		out[0] = 0x78; out[1] = 0x01;
		let at = 2;
		for (let b = 0; b < blocks; b++) {
			const start = b * 65535, len = Math.min(65535, data.length - start);
			out[at++] = b === blocks - 1 ? 1 : 0;
			out[at++] = len & 255; out[at++] = len >> 8;
			out[at++] = ~len & 255; out[at++] = (~len >> 8) & 255;
			out.set(data.subarray(start, start + len), at);
			at += len;
		}
		const sum = adler32(data);
		out[at++] = sum >>> 24; out[at++] = (sum >>> 16) & 255; out[at++] = (sum >>> 8) & 255; out[at++] = sum & 255;
		return out;
	}

	const TYPES = [null, "commit", "tree", "blob", "tag"];
	const OFS_DELTA = 6, REF_DELTA = 7;

	/**
	 * Apply a git delta.
	 * @param {Uint8Array} base - source object.
	 * @param {Uint8Array} delta - delta instructions.
	 * @returns {Uint8Array}
	 */
	function applyDelta(base, delta) {
		let pos = 0;
		function size() {
			let value = 0, shift = 0, c;
			do {
				c = delta[pos++];
				value += (c & 127) * 2 ** shift;
				shift += 7;
			} while (c & 128);
			return value;
		}
		if (size() !== base.length) throw new Error("delta: base size mismatch");
		const out = new Uint8Array(size());
		let at = 0;
		while (pos < delta.length) {
			const cmd = delta[pos++];
			if (cmd & 0x80) {
				let offset = 0, len = 0;
				if (cmd & 1) offset |= delta[pos++];
				if (cmd & 2) offset |= delta[pos++] << 8;
				if (cmd & 4) offset |= delta[pos++] << 16;
				if (cmd & 8) offset = (offset | (delta[pos++] << 24)) >>> 0;
				if (cmd & 16) len |= delta[pos++];
				if (cmd & 32) len |= delta[pos++] << 8;
				if (cmd & 64) len |= delta[pos++] << 16;
				if (len === 0) len = 0x10000;
				if (offset + len > base.length || at + len > out.length) throw new Error("delta: copy out of range");
				out.set(base.subarray(offset, offset + len), at);
				at += len;
			} else if (cmd) {
				if (at + cmd > out.length || pos + cmd > delta.length) throw new Error("delta: insert out of range");
				out.set(delta.subarray(pos, pos + cmd), at);
				at += cmd;
				pos += cmd;
			} else throw new Error("delta: unexpected opcode 0");
		}
		if (at !== out.length) throw new Error("delta: result size mismatch");
		return out;
	}

	/** One pack and its v2 index. */
	class Pack {
		constructor(fs, idxPath, packPath) {
			this.fs = fs;
			this.packPath = packPath;
			const idx = fs.readFileSync(idxPath);
			if (idx.length < 8 + 1024 || idx[0] !== 0xff || idx[1] !== 0x74 || idx[2] !== 0x4f || idx[3] !== 0x63) throw new UnsupportedObjects(`pack index ${idxPath} is not version 2`);
			const view = new DataView(idx.buffer, idx.byteOffset, idx.byteLength);
			if (view.getUint32(4) !== 2) throw new UnsupportedObjects(`pack index ${idxPath} is not version 2`);
			this.idx = idx;
			this.view = view;
			this.count = view.getUint32(8 + 255 * 4);
			this.names = 8 + 1024;
			this.offsets = this.names + this.count * 20 + this.count * 4;
			this.large = this.offsets + this.count * 4;
			this.data = null;
			this.fd = null;
		}

		/**
		 * The pack offset of an object, or -1.
		 * @param {Uint8Array} raw - 20-byte name.
		 */
		find(raw) {
			const first = raw[0];
			let lo = first === 0 ? 0 : this.view.getUint32(8 + (first - 1) * 4);
			let hi = this.view.getUint32(8 + first * 4);
			const idx = this.idx;
			while (lo < hi) {
				const mid = (lo + hi) >>> 1;
				const at = this.names + mid * 20;
				let cmp = 0;
				for (let i = 0; i < 20; i++) {
					if (idx[at + i] !== raw[i]) { cmp = idx[at + i] < raw[i] ? -1 : 1; break; }
				}
				if (cmp === 0) {
					const off = this.view.getUint32(this.offsets + mid * 4);
					if (!(off & 0x80000000)) return off;
					const at64 = this.large + (off & 0x7fffffff) * 8;
					return this.view.getUint32(at64) * 0x100000000 + this.view.getUint32(at64 + 4);
				}
				if (cmp < 0) lo = mid + 1;
				else hi = mid;
			}
			return -1;
		}

		/**
		 * Bytes of the pack from `offset`, at least `length` when the file has them.
		 * @param {number} offset - start.
		 * @param {number} length - wanted bytes.
		 * @returns {Uint8Array}
		 */
		read(offset, length) {
			const fs = this.fs;
			if (this.data === null && typeof fs.openSync === "function" && typeof fs.readSync === "function") {
				if (this.fd === null) this.fd = fs.openSync(this.packPath, "r");
				const buffer = new Uint8Array(length);
				let got = 0;
				while (got < length) {
					const n = fs.readSync(this.fd, buffer, got, length - got, offset + got);
					if (n <= 0) break;
					got += n;
				}
				return buffer.subarray(0, got);
			}
			if (this.data === null) this.data = fs.readFileSync(this.packPath);
			return this.data.subarray(offset, Math.min(this.data.length, offset + length));
		}

		/** Release the file descriptor. */
		close() {
			if (this.fd !== null) this.fs.closeSync(this.fd);
			this.fd = null;
		}
	}

	/** Thrown for repository layouts the module refuses to read. */
	class UnsupportedObjects extends Error {}

	/**
	 * Object databases: a primary directory new objects go to, plus alternates.
	 */
	class ObjectDb {
		/**
		 * @param {object} fs - host file system.
		 * @param {string} primary - absolute object directory that receives writes.
		 * @param {string[]} alternates - absolute alternate object directories.
		 */
		constructor(fs, primary, alternates) {
			this.fs = fs;
			this.primary = primary;
			this.dirs = [];
			this.cache = new Map();
			this.cacheBytes = 0;
			const seen = new Set();
			const add = (dir, depth) => {
				let real;
				try { real = fs.realpathSync(dir); } catch {
					if (depth === 0 && dir === primary) this.dirs.push({ dir, packs: null });
					return;
				}
				if (seen.has(real)) return;
				seen.add(real);
				this.dirs.push({ dir: real, packs: null });
				if (depth >= 5) return;
				let text;
				try { text = fromBytes(stringOf(fs.readFileSync(`${real}/info/alternates`))); } catch (error) {
					if (error && (error.code === "ENOENT" || error.code === "ENOTDIR")) return;
					throw error;
				}
				for (const line of text.split("\n")) {
					if (line === "" || line.startsWith("#")) continue;
					if (line.startsWith("\"")) throw new UnsupportedObjects("quoted alternate");
					add(line.startsWith("/") ? line : `${real}/${line}`, depth + 1);
				}
			};
			add(primary, 0);
			for (const dir of alternates) add(dir, 0);
		}

		packsOf(entry) {
			if (entry.packs) return entry.packs;
			entry.packs = [];
			let names;
			try { names = this.fs.readdirSync(`${entry.dir}/pack`); } catch { return entry.packs; }
			for (const name of names.sort()) {
				if (!name.endsWith(".idx")) continue;
				const pack = `${entry.dir}/pack/${name.slice(0, -4)}.pack`;
				try { this.fs.lstatSync(pack); } catch { continue; }
				entry.packs.push(new Pack(this.fs, `${entry.dir}/pack/${name}`, pack));
			}
			return entry.packs;
		}

		/**
		 * Whether any database holds an object.
		 * @param {string} oid - 40-character hex name.
		 */
		has(oid) {
			if (this.cache.has(oid)) return true;
			const raw = rawOf(oid);
			for (const entry of this.dirs) {
				try {
					this.fs.lstatSync(`${entry.dir}/${oid.slice(0, 2)}/${oid.slice(2)}`);
					return true;
				} catch { /* not loose here */ }
				for (const pack of this.packsOf(entry)) if (pack.find(raw) >= 0) return true;
			}
			return false;
		}

		/**
		 * Read an object.
		 * @param {string} oid - 40-character hex name.
		 * @returns {{type: string, data: Uint8Array} | null} null when no database has it.
		 */
		read(oid) {
			const hit = this.cache.get(oid);
			if (hit) return hit;
			const raw = rawOf(oid);
			let found = null;
			for (const entry of this.dirs) {
				found = this.readLoose(entry.dir, oid);
				if (found) break;
				for (const pack of this.packsOf(entry)) {
					const offset = pack.find(raw);
					if (offset >= 0) { found = this.readPacked(pack, offset); break; }
				}
				if (found) break;
			}
			if (found) this.remember(oid, found);
			return found;
		}

		remember(oid, object) {
			if (object.data.length > 1 << 20) return;
			this.cache.set(oid, object);
			this.cacheBytes += object.data.length;
			while (this.cacheBytes > 32 << 20) {
				const [first, value] = this.cache.entries().next().value;
				this.cache.delete(first);
				this.cacheBytes -= value.data.length;
			}
		}

		readLoose(dir, oid) {
			let file;
			try { file = this.fs.readFileSync(`${dir}/${oid.slice(0, 2)}/${oid.slice(2)}`); } catch (error) {
				if (error && (error.code === "ENOENT" || error.code === "ENOTDIR")) return null;
				throw error;
			}
			const { data } = inflate(file, 0);
			const space = data.indexOf(0x20), nul = data.indexOf(0);
			if (space < 0 || nul < space) throw new Error(`loose object ${oid} is corrupt`);
			const type = stringOf(data, 0, space);
			const size = Number(stringOf(data, space + 1, nul));
			if (!TYPES.includes(type) || size !== data.length - nul - 1) throw new Error(`loose object ${oid} is corrupt`);
			return { type, data: data.subarray(nul + 1) };
		}

		/**
		 * One entry of a pack, resolving delta chains.
		 * @param {Pack} pack - the pack.
		 * @param {number} offset - entry offset.
		 */
		readPacked(pack, offset) {
			const chain = [];
			let base = null;
			for (let depth = 0; ; depth++) {
				if (depth > 10000) throw new Error("pack: delta chain too long");
				const head = pack.read(offset, 32);
				let c = head[0], used = 1;
				const type = (c >> 4) & 7;
				let size = c & 15, shift = 4;
				while (c & 0x80) {
					if (used >= head.length) throw new Error("pack: bad object header");
					c = head[used++];
					size += (c & 127) * 2 ** shift;
					shift += 7;
				}
				if (type === OFS_DELTA) {
					c = head[used++];
					let back = c & 127;
					while (c & 128) {
						c = head[used++];
						back = (back + 1) * 128 + (c & 127);
					}
					chain.push(this.inflateAt(pack, offset + used, size));
					offset -= back;
					continue;
				}
				if (type === REF_DELTA) {
					const baseOid = hexOf(head, used, used + 20);
					chain.push(this.inflateAt(pack, offset + used + 20, size));
					base = this.read(baseOid);
					if (!base) throw new Error(`pack: missing delta base ${baseOid}`);
					break;
				}
				if (!TYPES[type]) throw new Error("pack: bad object type");
				base = { type: TYPES[type], data: this.inflateAt(pack, offset + used, size) };
				break;
			}
			let data = base.data;
			for (let i = chain.length - 1; i >= 0; i--) data = applyDelta(data, chain[i]);
			return { type: base.type, data };
		}

		inflateAt(pack, offset, size) {
			let window = Math.max(4096, size + (size >> 2) + 64);
			for (;;) {
				const bytes = pack.read(offset, window);
				try { return inflate(bytes, 0, size).data; } catch (error) {
					if (!(error instanceof Truncated) || bytes.length < window) throw error;
					window *= 2;
				}
			}
		}

		/**
		 * Store an object as a loose object in the primary directory unless a
		 * database already holds it.
		 * @param {string} type - object type.
		 * @param {Uint8Array} data - object body.
		 * @returns {string} the object name.
		 */
		write(type, data) {
			const oid = hashObject(type, data);
			if (this.has(oid)) return oid;
			const header = encoder.encode(`${type} ${data.length}\0`);
			const full = new Uint8Array(header.length + data.length);
			full.set(header);
			full.set(data, header.length);
			const dir = `${this.primary}/${oid.slice(0, 2)}`;
			this.fs.mkdirSync(dir, { recursive: true });
			const tmp = `${this.primary}/tmp_obj_${oid}_${Date.now().toString(36)}${Math.random().toString(36).slice(2)}`;
			this.fs.writeFileSync(tmp, deflateStored(full));
			this.fs.renameSync(tmp, `${dir}/${oid.slice(2)}`);
			if (data.length <= 1 << 20) this.remember(oid, { type, data });
			return oid;
		}

		/** Release open pack files. */
		close() {
			for (const entry of this.dirs) for (const pack of entry.packs ?? []) pack.close();
		}
	}

	root.DshNativeGitObjects = {
		toBytes, fromBytes, bytesOf, stringOf, hexOf, rawOf,
		Sha1, hashObject, inflate, deflateStored, adler32, applyDelta,
		ObjectDb, Truncated, UnsupportedObjects,
	};
})(globalThis);
